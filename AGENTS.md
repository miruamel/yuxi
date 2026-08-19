# Yuxi (玉溪) — Autonomous Software Evolution Engine

Zig 0.16.0 project rooted at `src/` (root = `src/`). Implements the autonomous
evolution engine described in `DESIGN.md`.

## Build & Run
```bash
/opt/zig/zig build                 # produces zig-out/bin/yuxi
./zig-out/bin/yuxi --no-hitl --mock --task "write a function that adds two ints"
./zig-out/bin/yuxi --hitl --local --task "..."   # --hitl reserved; engine auto-deploys on verified (see Open questions)
- ./zig-out/bin/yuxi --no-hitl --mock --task "add two numbers" --expect "step result: 2+3=5"
```

## CLI flags
- `--hitl` / `--no-hitl` — human-approval mode vs fully autonomous (default no_hitl).
- `--mock` / `--openai` / `--local` — LLM backend.
- `--task TEXT` or trailing arg — the task prompt.
- `--out DIR` — workdir (default `ae_out/`); isolated git repo lives here.
- `--cache[=DIR]` — opt-in on-disk LLM-response cache (default `.yuxi_cache`).
- `--expect TEXT` — behavioral verification (see below).
- `--max-tokens N` — soft LLM-spend ceiling; `engine.run` aborts the build loop
  once `ctx.tokens` reaches N, records `engine: token budget exceeded`, deploys
  nothing. Default off.

## Verify
```bash
/opt/zig/zig build                  # compile binary
/opt/zig/zig build test             # cache unit test
/opt/zig/zig fmt --check src        # lint
```

## Architecture (`src/`)
- `main.zig` — entry; loads config, optional `--cache`, builds `Ctx`, runs engine.
- `core/{types,config,engine}.zig` — `Ctx` state, CLI parse, the 9-layer loop.
- `llm/transport.zig` — single LLM entry `complete(...)`. Backends: mock (offline),
  openai (`OPENAI_BASE`/`OPENAI_API_KEY`), local (ollama `LOCAL_BASE`).
- `gateway orchestrator builder critic evaluator deploy resilience knowledge monitoring`
  — one module per layer.
- `util/{fs,cache}.zig` — posix file IO; on-disk LLM-response cache.

## Incremental LLM cache (feat, v0.1)
`--cache[=DIR]` enables `util/cache.zig`. `transport.complete` keys on
sha256(backend \0 system \0 user) and serves prior responses from disk without
re-calling the model. Opt-in; default dir `.yuxi_cache`. Cache hits also skip the
`ctx.tokens` increment, so monitoring reports real generation cost.

## Deploy layer (verified checkpoint)
The composed `gen_final.zig` (one per task) is committed into an *isolated* git repo inside
`ctx.workdir` (default `ae_out/`) via `deploy.run`: `git -C <wd> init` + add
+ commit. Keeps engine-run artifacts out of the engine repo. Commits use an
explicit identity (`git -c user.name=Yuxi Engine -c user.email=yuxi@localhost`)
because the spawned `git` inherits no identity in this env.
**Gating:** `engine.zig` only calls `deploy.run` when `evaluator.run`
(`zig build-exe` compile + run) returns true. Invalid output is never committed and no
workdir repo is created.
- **Cleanup:** after a successful deploy, per-step `gen_{i}.zig` fragments are
  deleted (best-effort) so only `gen_final.zig` remains in `ctx.workdir`.
  On evaluation failure the intermediates are kept for debugging.

## Self-correction (feat)
The engine retries the build+compose+evaluate pipeline up to 3 times when
`evaluator.run` fails. On each failed attempt the compiler/run `stderr` is
captured on `ctx.eval_error` and fed back into the builder prompt
(`builder.promptFor`), so an LLM backend (`.openai`/`.local`) can correct
non-compiling generated code. The mock backend emits deterministic, valid Zig,
so it always succeeds on attempt 1 and never exercises the retry path.
On the final failed attempt the intermediates are kept (`gen_*.zig` +
`gen_final.zig`) for debugging, as before.
The critic's verdict also feeds back: a `REJECT` regenerates the rejected
step with the critic's reason as builder feedback before any mock fallback.

## Behavioral verification (feat)
`--expect TEXT` runs behavioral verification: after the evaluator compiles+runs
the composed artifact, its captured stdout (trimmed) must equal `TEXT`. A mismatch
sets `ctx.eval_error`, which the self-correction loop feeds back to the builder as
`feedback` (up to 3 retries) — so an LLM backend can correct behavior, not just
compile errors. Mock backend output is deterministic, so `--expect "step result: 2+3=5"`
passes and `--expect "nope"` triggers the retry path.
- **Mock internals (don't regress):** the mock orchestrator always decomposes
  into a fixed 3-step plan; only the final `add a unit test` step emits output,
  so the composed binary prints a single line and `--expect` matches
  deterministically. Making the other steps also print re-breaks `--expect`
  (tripled output → self-correction exhausts without a deploy).
- `loop.runTasks` (`--tasks`) gives each task its own nested workdir
  `<workdir>/<idx>`; `fs.ensureDir` now creates the missing parent, so a
  fresh workdir no longer fails with `DirCreateFailed`.

## Knowledge base (feat)
`--kb[=DIR]` enables a persistent lesson ledger the engine learns from across
runs — the core autonomous-evolution loop. Each run appends one line to `<DIR>`
outcome (deployed/failed) plus degradation counters (critic_rejections, mock_fallbacks, token_budgets_exceeded); step count, deploys, retries; the orchestrator
prepends prior lessons to its decomposition prompt so later runs avoid
repeating failures. Opt-in and off by default (`Ctx.kb_path = null`): with
`--kb` unset no file I/O occurs and every existing test/pipeline path is
unchanged. The mock backend ignores injected context, so prompt shape never
affects mock output (and the engine test stays green).

## Run metrics (observability, feat)
`Ctx` carries five autonomy-health counters incremented at their event
sites: `critic_rejections`, `mock_fallbacks`, `retries` (self-correction
rebuilds), `deploys`, `token_budgets_exceeded`. `monitoring.report` emits
them alongside events/tokens so the loop can read its own effectiveness
(critic reject rate, mock-fallback frequency, retry churn, deploy rate)
without parsing event strings.

## Smoke test & gotchas
End-to-end check, offline (no API key):
```bash
/opt/zig/zig build-exe src/main.zig -femit-bin=/tmp/yuxi_bin -O Debug
rm -rf /tmp/smoke && mkdir -p /tmp/smoke && cd /tmp/smoke
/tmp/yuxi_bin --no-hitl --mock --cache --task "add two numbers"
git -C ae_out log --oneline      # expect 3 commits (mock emits valid Zig)
```
Gotchas paid for this cycle:
- **Rebuild the /tmp binary after every source edit.** `zig build-exe` is not
  watched; smoking a stale binary wasted a cycle (the deploy-identity fix was
  hidden behind a pre-edit binary once).
- **`rm -rf ae_out` can fail EACCES on `.git/objects`** (Android overlay fs).
  Use a fresh smoke dir instead of `rm`.
- **Spawned `git` has no identity here** — rely on the `-c` flags, never
  assume global `user.name/email` exists.

- **Memory is tight (~354MB free / 4.3GB used):** a full pipeline smoke can OOM.
  Prefer `zig build test` unit/engine tests over launching the binary end-to-end.
- **CI installs Zig via `mlugg/setup-zig@v2`** (the `goto-bus/setup-zig` slug is a
  404). `zig fmt --check src` is the CI lint command (not `.`); `gen_*.zig` are
  gitignored so they don't trip the check.
- **`std.process.run` does not pipe stdio in 0.16** (captured stdout comes back
  empty despite `.pipe` options); the evaluator captures output via
  `std.process.spawn` + a temp file redirect + `fs.readFileAlloc`.


## Invariants (from DESIGN.md)
<=5 files/dir, <=200 SLOC/file, deep nesting by capability.
Flat imports from `src/`: `@import("core/types.zig")`, not `../core/types.zig`.

## Known gaps (next cycles)
- Remote `miruamel/yuxi` (public) provisioned; `master` pushed, CI green on push to
  `master`/`main`. Release tagging still batched per §28 (no tag cut yet).
- The engine now composes every step into ONE runnable program (`gen_final.zig`):
  each step emits a `pub fn stepN() void` fragment, the engine merges them under a
  `main` harness, and the evaluator compiles+runs the single artifact. Deploy gates
  on a clean compile+run; one artifact per task, not N disconnected files.
- Evaluator has a regression test (`src/evaluator/evaluator.zig`): a compiling
  program is accepted and a non-compiling one is rejected, via a real
  `zig build-exe` + run using the pre-initialized `std.Io.Threaded.global_single_threaded`
  host Io (avoids allocating an Io, which would panic under `zig build test`'s
  failing-allocator re-run). `src/tests.zig` is the test root, so `zig build test`
  covers cache, evaluator, engine composition, and three engine-level integration
  tests in `src/core/selfcorr_test.zig`: self-correction recovery (fail-first
  injected backend), critic denylist block (process-spawning code never deploys),
  and token-budget abort (`--max-tokens 1`). All use the `Ctx.llm_fn` seam or the
  mock backend — no network, deterministic.
- Real LLM backends (`.openai`/`.local`) shell `curl` (`transport.httpComplete`); `curl`
  must be on PATH at runtime. `extractContent` unescapes JSON `\n`/`\t` so multi-line
  generated code survives the OpenAI response — a regression test now guards this.
- `.gitignore` covers binaries, build dirs, `gen_*.zig`, `.yuxi_cache`, `/ae_out/`.

## Recent cycles (category balance, §14)
- `fac5fa4` feat: persistent knowledge base (--kb) learns lessons across runs (§11/§12).
- `d1c7cc0` feat: enrich knowledge-base lessons with degradation counters (§12).
- `3a16e4d` feat: batch task execution via --tasks (loop.runTasks: per-task workdir + batch health report).
- `d759878` fix: ensureDir creates nested parent dirs (unbreaks --tasks workdir; was DirCreateFailed).
- `eef6a4f` fix: mock emits single-line output so --expect matches (was tripled by 3-step compose).
- `8b62080` feat: structured run metrics for autonomy health (§30/§32).
- `1ae73b6` feat: end-of-run autonomy-health verdict consumes run metrics (§30/§32).
- `d4a64c2` docs: README current with `--max-tokens` + run-metrics counters (§24).
- `da06e74` refactor: extract step build into src/core/step.zig (§8 SLOC cap).
- `ff96295` feat: token/cost budget cap (`--max-tokens`).
- `d60859b` test: engine-level critic denylist integration test (via `Ctx.llm_fn` seam).
- `9b58ab0` ci: fixed broken `goto-bus/setup-zig` → `mlugg/setup-zig@v2`.
- `93b7e97` feat: injectable LLM backend seam (`Ctx.llm_fn`) + self-correction loop test.
- `6ed8f54` feat: behavioral verification (`--expect`) with file-captured output.

## Open questions (for the co-owner, not silently built)
- `--dry-run` / plan mode (Product-shaping fork; needs co-owner call): what
  should it surface — the decomposed `STEP:` plan only, the critic verdict on
  the first generated artifact, or the full eval result? **My lean: plan +
  critic verdict, not full eval** — eval requires a full build and defeats the
  "cheap preview before spending tokens" purpose; plan+verdict is enough to
  sanity-check direction. **Stakes:** surfacing full eval turns the mode into a
  second pipeline run (not a preview); plan-only hides whether the critic would
  reject the code.
- `--hitl` deploy gating (Product-shaping fork; needs co-owner call): flag is
  parsed but the engine auto-deploys on verified regardless of mode. **My lean:
  keep auto-deploy as default (honors the autonomous owner mandate) and make
  `--hitl` gate only the write/commit step, not compile+run eval** — human
  approval before the artifact is persisted, but the loop still self-verifies.
  **Stakes:** gating eval behind a human breaks the autonomous loop and the §30
  runtime-feedback signal; gating only persistence keeps oversight at the
  irreversible boundary without throttling self-correction.
