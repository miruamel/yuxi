# Yuxi (玉溪) — Autonomous Software Evolution Engine

Zig 0.16.0 project rooted at `src/` (root = `src/`). Implements the autonomous
evolution engine described in `DESIGN.md`.
Versioning is git-tag based — no `version` constant lives in `src/` or
`build.zig`, so a release is purely a tag + `gh release` from a CI-green master.
v0.1.0 (2026-08-19) and v0.2.0 (2026-08-20) are source tags (no binaries
attached). Cut a release when a coherent batch of merged work accumulates
(§28) — not per-PR.

## Build & Run
```bash
/opt/zig/zig build                 # produces zig-out/bin/yuxi
./zig-out/bin/yuxi --no-hitl --mock --task "write a function that adds two ints"
./zig-out/bin/yuxi --hitl --local --task "..."   # --hitl reserved; engine auto-deploys on verified (see Open questions)
- ./zig-out/bin/yuxi --no-hitl --mock --task "add two numbers" --expect "step result: 2+3=5"
```

## CLI flags
`yuxi --help` prints the authoritative, always-current flag list — treat it as
the source of truth and keep it in sync when adding flags (the help string
lives in `core/config/config.zig: printHelp`).
- `--hitl` / `--no-hitl` — human-approval mode vs fully autonomous (default no_hitl).
- `--mock` / `--openai` / `--local` — LLM backend.
- `--task TEXT` or trailing arg — the task prompt.
- `--out DIR` — workdir (default `ae_out/`); isolated git repo lives here.
- `--cache[=DIR]` — opt-in on-disk LLM-response cache (default `.yuxi_cache`).
- `--replay[=FILE]` — opt-in recorded-LLM-response file; `transport.complete` serves entries in call order for `.openai`/`.local` without calling the network (offline CI/tests). Entries delimited by `---` lines.
- `--record[=FILE]` — opt-in capture of every real (non-seam, non-replay) LLM
  response into a file; `engine.run` flushes them as `--replay`-compatible
  entries (delimited by `---` lines). Default file `.yuxi_record.txt`. Pair
  with `--replay` to record a run once, then drive it offline forever.
- `--expect TEXT` — behavioral verification (see below).
- `--max-tokens N` — soft LLM-spend ceiling; `engine.run` aborts the build loop
  once `ctx.tokens` reaches N, records `engine: token budget exceeded`, deploys
  nothing. Default off.
- `--kb[=DIR]` / `--kb-max-lines[=N]` — knowledge ledger path and injection cap
  (bare `--kb-max-lines` = 200, default off). See Knowledge base (feat) below.
- `--tasks FILE` — batch mode: run each non-comment, non-blank line as an
  isolated engine cycle and aggregate the autonomy-health report (see
  `loop.zig`).

## Verify
```bash
/opt/zig/zig build                  # compile binary
/opt/zig/zig build test             # cache unit test
/opt/zig/zig fmt --check src        # lint
```

## Architecture (`src/`)
- `main.zig` — entry; loads config, optional `--cache`, builds `Ctx`, runs engine.
- `core/{types,engine,compose}.zig` + `core/config/config.zig` — `Ctx` state, the 9-layer loop, fragment composition; CLI parse lives in `core/config/`.
- `llm/transport.zig` — single LLM entry `complete(...)`. Backends: mock (offline),
  openai (`OPENAI_BASE`/`OPENAI_API_KEY`), local (ollama `LOCAL_BASE`).
  `llm/http.zig` — network path: `http.complete` shells `curl` with bounded
  retries (3 attempts, 250ms·n backoff) + `-m 60 --connect-timeout 10` so a
  transient failure doesn't abort the build or silently fall back to mock.
- `gateway orchestrator builder critic evaluator deploy resilience knowledge monitoring`
  — one module per layer.
- `util/{fs,cache}.zig` — posix file IO; on-disk LLM-response cache.

## Incremental LLM cache (feat, v0.1)
`--cache[=DIR]` enables `util/cache.zig`. `transport.complete` keys on
sha256(backend \0 system \0 user) and serves prior responses from disk without
re-calling the model. Opt-in; default dir `.yuxi_cache`. Cache hits also skip the
`ctx.tokens` increment, so monitoring reports real generation cost.
## Offline replay mode (feat)
`--replay[=FILE]` makes `transport.complete` serve recorded LLM responses in
call order instead of calling the network, when the backend is `.openai` or
`.local` and `Ctx.replay_path` is set. Entries are separated by a line that is
exactly `---`, so a recorded response may span multiple lines (e.g. a
decomposer plan). `Ctx.replay_idx` tracks position; running past the last entry
is a hard error. Off by default (null): production needs no replay file, and
the mock backend is unaffected. Purpose: exercise the real `.openai`/`.local`
dispatch — including curl auth, response handling, and the full engine loop —
offline, with no API key, for CI and integration tests. `transport_test.zig`
covers ordered playback (unit) and a full `engine.run` deploy through the
real openai path via replay.
- **Network retry (feat):** `http.complete` (llm/http.zig) now retries the curl
  call up to 3 times with linear backoff (250ms·attempt) and passes `-m 60
  --connect-timeout 10` to curl, so a transient 5xx/connection-reset/timeout no
  longer aborts the build and triggers a silent mock fallback. Persistent
  failure still propagates `error.RequestFailed` for `resilience.fallback` to
  handle. `transport.zig` delegates the network path to `http.complete`; the
  mock/replay/cache paths are untouched. `http.zig` carries the JSON-escape and
  content-extraction unit tests moved out of `transport.zig` (which shrank to a
  dispatch stub).
  consumes verbatim, so a single real (or mock) run can be replayed through the
  real `.openai`/`.local` dispatch offline with no API key. `transport_test.zig`
  proves the round-trip end-to-end (mock capture -> offline replay deploy).

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
- **Gateway sanitizer is live (not a no-op):** `gateway.run` returns the
  *redacted* task on admission; `engine.run` uses that sanitized slice for
  `orchestrator.run` and `knowledge.recordLesson` (and frees it), so codegen
  and the KB ledger operate on PII-scrubbed text. Denial (short task / empty
  `AE_TOKEN`) returns `null` and nothing runs. Don't regress by feeding the
  raw `task` to the orchestrator again.
- **Redactor hardens email leakage:** the earlier `redact` only replaced `@`
  and swallowed the rest of the @-run, so `user@corp.com` leaked as
  `user<redacted>corp.com` — the domain stayed visible. `redact` now replaces
  the WHOLE whitespace token containing `@` (`user@corp.com` -> `<redacted>`),
  preferring over-redaction at the trust boundary. `gateway_test.zig` covers
- **Plan-quality gate (feat):** `engine.run` now reviews the orchestrator's
  decomposition *before* codegen (LAYER 2.5, between orchestrator and the
  per-step build/critic loop). `critic.reviewPlan` reuses the critic transport
  + `parseVerdict` with a plan-specific prompt; on REJECT it increments
  `ctx.critic_rejections`, persists a `knowledge.recordCritic("plan", …)`
  lesson, logs `engine: ABORT at plan critic`, and returns before any codegen
  or deploy. Always-on, fail-fast, non-breaking — the mock/test backend
  returns APPROVE by default. `plan_gate_test.zig` exercises the reject path
  end-to-end via the `Ctx.llm_fn` seam.
- **Test seam convention (don't regress):** the plan reviewer is *distinct*
  from the per-step code critic. The plan reviewer's system prompt deliberately
  omits the word "critic" and sends a `"Plan:\n…"` user-prompt prefix; the
  per-step code critic uses a `"critic"` system string and a `"Review:\n…"`
  user prefix. Injected-backend tests that distinguish the two must key on
  those prefixes, not on a shared "critic" substring — otherwise the plan call
  is misrouted and desyncs the replay/test transcript.
- **Plan-gate learning loop must not be truncated (fix):** the LAYER 2.5
  plan-reject path in `engine.run` was a bare `return` that skipped LAYER
  7-9 (resilience, `recordLesson` with `critic_rej=N`, `monitoring.report` +
  `recordHealth`). So a rejected plan never wrote its numeric critic-rejection
  counter to the KB ledger and never persisted a health verdict — the next
  cycle's `injectPrompt` couldn't steer away from a plan-shaped failure. The
  early aborts (gateway, orchestrator, plan critic, no-verify) now all tail-call
  `finishRun` (LAYER 7-9), so every exit path records outcome + health. Don't
  re-introduce a bare early-return in `engine.run`.
- **`engine.fileExists` moved to `util/fs.zig`:** it's a pure filesystem
  predicate; keeping it in engine.zig pushed that file past the 200-SLOC
  invariant (§8). Tests now call `fs.fileExists`, not `engine.fileExists`.
- **Builder fallback must count `mock_fallbacks` (fix):** `builder.run` calls
  `resilience.fallback(ctx)` on a transport error but previously never
  incremented `ctx.mock_fallbacks` — unlike the per-step critic fallback in
  `step.zig`. So the autonomy-health signal (`assessHealth`'s "mock fallback
  dominated" WARN) and `recordLesson`'s `mock_fb=N` under-counted builder-level
  fallbacks, letting a mock-dominated cycle slip past the health check. The
  fallback path now increments `ctx.mock_fallbacks` (matching `step.zig`), so
  the signal fires regardless of where the fallback originated. `builder_test.zig`
  covers the fail-then-succeed seam path.




## AI review bot (co-owner signal)
`Kilo Code Review` runs as a required-ish check on every PR (shows as a
check named "Kilo Code Review"). Treat its verdict as a co-owner review: read
`gh api pulls/<n>/reviews` + `/comments` + `issues/<n>/comments` after the
check flips to `completed`, and act on any CRITICAL/WARNING before merge (a
SUGGESTION is judgment-call). PR #6 came back `No Issues Found | Merge`. Don't
merge past a bot-flagged CRITICAL without addressing it (or a documented
reason). The bot may take a few minutes after CI — don't block the
whole loop on it, but do consume its result.

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
Critic `REJECT` reasons are persisted too (`knowledge.recordCritic`), so
future decompositions can steer away from the rejected shape — not only the
numeric `critic_rej=N` counter that `recordLesson` records.
- **Health-verdict loop (feat):** `monitoring.assessHealth` now returns the
  accumulated autonomy-health verdict (e.g. `no deploy; self-correction
  exhausted; `) instead of only logging it. `engine.run` persists that verdict
  to the KB via `knowledge.recordHealth` on an unhealthy cycle, so the next
  run's `injectPrompt` also steers away from an *unhealthy cycle shape*
  (mock-dominated, budget-exhausted) — not only from a fixed failure or a
  rejected step. A healthy cycle produces no health lesson.
- **Batch summary loop (feat):** `--tasks` runs already aggregated a per-batch
  autonomy-health report in `loop.runTasks`, but only *logged* it. `loop` now
  persists that aggregate via `knowledge.recordBatch` (tasks + total deploys +
  unhealthy count) to the configured KB, so `injectPrompt` also learns *batch
  shape* (e.g. every task mock-fell-back, none deployed) — not only the
- **KB growth bound (feat):** `--kb-max-lines[=N]` caps how many prior lessons
  `injectPrompt` prepends to the decomposition prompt (defaults to 200 when
  given bare). The ledger is append-only, so without the cap every run loads
  the *entire* file into its prompt — unbounded bloat on a long-lived engine.
  Null by default (no cap = historical behavior). Wire: `config.kb_max_lines`
  → `Ctx.kb_max_lines` → `knowledge.injectPrompt` → `tailLessons`.

`Ctx` carries six autonomy-health counters incremented at their event sites:
critic_rejections, mock_fallbacks, retries (self-correction rebuilds), deploys,
network_retries (recovered HTTP retries from `http.complete`), and
token_budgets_exceeded. `monitoring.report` emits them alongside events/tokens
so the loop can read its own effectiveness (critic reject rate, mock-fallback
frequency, retry churn, deploy rate) without parsing event strings.
`network_retries` is observability-only: a recovered transient network blip is
NOT a degradation, so it never trips `assessHealth` (unlike `mock_fallbacks`).
`llm/http.zig` is the only network path and the only place that shells out
(via `std.process.run`). It invokes `curl` with **array argv** (never a shell),
so `url`/`body`/`key` are passed positionally and cannot inject shell
commands — do NOT "simplify" this to a `sh -c`/string-command invocation.
`jsonEscape` escapes the full RFC 8259 control range (U+0000–U+001F) because
the prompt path carries semi-trusted input (KB lessons, recorded evaluator
errors, task text) that can contain raw control bytes; an unescaped one
yields malformed JSON → server rejection → silent mock fallback.

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

## Test runner (module-name imports)
`zig build test` runs every `test` block in the tree. Zig 0.16 only collects
`test` blocks from the **root module** of a test build, so a single aggregator
file can't pull in other files' tests. Every source file is a public named
module (`@import("types")`, registered in `build.zig`), and each test-bearing
file is its own `addTest` root wired with the all-to-all module imports (the
dependency graph is a DAG, so no per-file import list is needed). Sub-directory
test files can't be roots with relative `../` imports (they escape the module
path), which is why imports are by name.

**Gotcha 1 — false-green (issue #3):** `b.addTest` returns a *compile* step.
Depending only on `tt.step` compiles the tests but never *runs* them — `zig
build test` exits 0 while no test executes. You MUST `addRunArtifact(tt)` and
depend on `run_tt.step` so the binaries actually execute; then a failing test
fails the build. CI green genuinely means the tests ran and passed.

**Gotcha 2 — `zig_test` IPC deadlock (aarch64):** `addRunArtifact(tt)` for a
test artifact injects `--listen=-` and switches to the `zig_test` server
protocol. On aarch64 with the default LLVM backend the protocol pipe deadlocks
(the engine test spawns child processes that inherit the pipe fds). Run test
binaries **directly** instead: build with `b.addTest`, then `const run_tt =
std.Build.Step.Run.create(b, ...); run_tt.addArtifactArg(tt);
run_tt.stdio = .inherit;`. That executes the self-managed binary (no
`--listen`) and checks the exit code. Don't use `use_llvm = false` to dodge
this — the self-hosted aarch64 backend is far too slow for 13 roots.

**Gotcha 3 — child processes need a real allocator AND a real environment:**
`evaluator.runTo` spawns `zig build-exe` via `std.process.spawn`. It must NOT
use `ctx.io` (`std.Io.Threaded.global_single_threaded`): that Io's allocator
is `.failing` (see `init_single_threaded`), so the argv/env arena alloc OOMs.
Create a per-call `std.Io.Threaded.init(ctx.allocator, .{ .environ =
std.Io.Threaded.global_single_threaded.environ.process_environ })` — a real
allocator for the spawn, and the real OS environment (a default-initialized
`Threaded` has an *empty* environ, which makes the child `zig` fail with
`AppDataDirUnavailable` because it can't resolve its cache dir). Unit tests
that spawn `zig` must pass real environment too (or absolute paths + a real
env), never rely on an inherited-empty one.

**Speed:** each root recompiles its module graph, so the full suite is slow on
this environment (~20-40s/root, ~4-7 min total). Give local/CI runs enough
wall time; don't shrink `test_files` to fit a tighter timeout. To add a test,
drop a `test` block in the relevant file and list the file in `build.zig`'s
`test_files`.

**Unit-test hygiene:** tests that call `evaluator.run` (or `engine.run`)
intentionally leave `ctx.events` / `ctx.eval_error` allocated at exit (the CLI
owns those). In a unit test use `std.heap.page_allocator` (not
`std.testing.allocator`) so the DebugAllocator leak check doesn't false-fail;
and free `eval_error` via `ctx.clearEvalError()` (which nulls the field),
never a bare `ctx.allocator.free(e)` that leaves a dangling pointer for a later
`clearEvalError` to double-free.
- Real LLM backends (`.openai`/`.local`) shell `curl` via `http.complete`
  (llm/http.zig), which retries up to 3 times with backoff and a 60s/10s curl
  timeout. `extractContent` unescapes JSON `\n`/`\t` so multi-line generated
  code survives the OpenAI response — a regression test now guards this.
- `.gitignore` covers binaries, build dirs, `gen_*.zig`, `.yuxi_cache`, `/ae_out/`.

## Recent cycles (category balance, §14)
- `74d93fd` feat: offline record mode (--record) captures a --replay-compatible transcript; closes the record/replay loop (§12).
- `7ae51bc` refactor: split core/selfcorr_test.zig (241 SLOC, §8 breach) into core/selfcorr/{recovery,gate}_test.zig; deepens nesting, frees core/ 5-file cap (§8/§9).
- `5521d48` feat: offline replay mode (--replay) drives real .openai/.local backend path offline for CI/tests (§11/§21).
- `fac5fa4` feat: persistent knowledge base (--kb) learns lessons across runs (§11/§12).
- `d1c7cc0` feat: enrich knowledge-base lessons with degradation counters (§12).
- `3a16e4d` feat: batch task execution via --tasks (loop.runTasks: per-task workdir + batch health report).
- `d759878` fix: ensureDir creates nested parent dirs (unbreaks --tasks workdir; was DirCreateFailed).
- `0ea3f5a` test: cover LLM-critic REJECT recovery branch (step.zig 23-47) via injected backend; complements denylist fallback test (§11/§21).
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
- `c91df1e` refactor+feat: extract `engine.compose` → `src/core/compose.zig` (§8 SLOC cap) + close monitoring→knowledge health loop (`knowledge.recordHealth`); PR #4 / issue #3 closed.
- `3284de8` fix(evaluator): resolve `zig` exe path portably (`/opt/zig/zig` else `zig` on PATH) — was green locally, `FileNotFound` only in CI.
- `b66179d` feat(kb): `--tasks` batch runs persist aggregate health summary to KB via `knowledge.recordBatch` (closes the batch-learning loop; §12); PR #5.
- `19c1bde` fix(gateway): sanitizer was a silent no-op — `gateway.run` redacted the task then discarded it, so orchestrator + KB ran on raw text. Now returns the owned redacted slice; `engine.run` uses it downstream. New `gateway_test.zig`. Kilo Code Review: No Issues Found | Merge. PR #6.
- `HEAD` fix(security): redactor leaked email domains — `redact` only replaced `@` so `user@corp.com` became `user<redacted>corp.com`. Now redacts the whole @-token (`user@corp.com` -> `<redacted>`); over-redaction at trust boundary. Gateway tests cover admission + whole-email + no-PII passthrough.

- `HEAD` feat(core): plan-quality critic gate — review decomposition before codegen (LAYER 2.5); fail-fast on REJECT, persist plan lesson. New plan_gate_test.zig. Resolves §14 feature-bias drift (5 non-feature cycles).
- `--dry-run` / plan mode (Product-shaping fork; needs co-owner call): what
  should it surface — the decomposed `STEP:` plan only, the critic verdict on
- `HEAD` refactor(monitoring): `assessHealth` is now the single source of truth for cycle health — returns `HealthVerdict { verdict, healthy }`. `loop.runTasks` no longer re-derives `healthy` (old `deploys>0 && budget==0` ignored `mock_fallback>deploys`); it calls `assessHealth` and prints the verdict per task, so the batch report can never contradict the per-cycle verdict persisted to the KB. `engine.finishRun` updated to the struct form. `monitoring_test` covers both shapes.

  critic verdict, not full eval** — eval requires a full build and defeats the
  "cheap preview before spending tokens" purpose; plan+verdict is enough to
  sanity-check direction. **Stakes:** surfacing full eval turns the mode into a
  second pipeline run (not a preview); plan-only hides whether the critic would
  reject the code.
- `--hitl` deploy gating (Product-shaping fork; needs co-owner call): flag is
  parsed but the engine auto-deploys on verified regardless of mode. **My lean:
  keep auto-deploy as default (honors the autonomous owner mandate) and make
  `--hitl` gate only the write/commit step, not compile+run eval** — human
- `HEAD` fix(core): plan-reject no longer truncates the learning loop — early aborts (gateway/orchestrator/plan-critic/no-verify) now tail-call `finishRun` (LAYER 7-9) so every exit path records the outcome + health verdict to the KB; moved `fileExists` to `util/fs.zig` to keep `engine.zig` ≤200 SLOC (§8).
  **Stakes:** gating eval behind a human breaks the autonomous loop and the §30
  runtime-feedback signal; gating only persistence keeps oversight at the
  irreversible boundary without throttling self-correction.

Resolved (no longer open): issue #1 (gateway rate-limit no-op) — the dead
per-call counter was removed in `dc7f217`; gateway now does auth + validation
+ PII redaction only. Closed as *remove* (option B).

Tracked for co-owner decision: issue #2 (--dry-run plan scope; --hitl gating scope).
