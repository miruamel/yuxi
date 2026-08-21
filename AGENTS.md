# Yuxi (玉溪) — Autonomous Software Evolution Engine

Zig 0.16.0 project rooted at `src/` (root = `src/`). Implements the autonomous
evolution engine described in `DESIGN.md`.
Versioning is git-tag based. `build.zig` stamps the binary at build time via
`git describe --tags --always --dirty`, injecting it into every module as
`build_options.version` (no hand-maintained `version` constant in `src/`);
`--version`/`-V` prints `yuxi <tag>` and exits 0. A release is still purely a
tag + `gh release` from a CI-green master; the tag now also flows into the
binary and the JSON health report's `version` field.
v0.1.0 (2026-08-19), v0.2.0 (2026-08-20), v0.3.0 are source tags (no binaries
attached). Cut a release when a coherent batch of merged work accumulates
(§28) — not per-PR.


## Autonomous agent governance

This repo is operated by a fully autonomous, non-HITL agent. The complete
governance summary — escalation tiers, mandatory public claiming / PR-context
comment transparency, split-changelog provenance, and the non-negotiable
`--jobs 2` resource cap — lives in
[`AUTONOMOUS_AGENT.md`](AUTONOMOUS_AGENT.md) and is linked from the README.
Open co-owner forks (#2 `--dry-run`/`--hitl`, #41 generated-code runtime
sandbox) are tracked as `question` issues and are **not** built silently.

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
- **Gateway auth (env, not a flag):** `AE_TOKEN` is an optional presence gate.
  For a *real* secret, set `AE_TOKEN_EXPECTED=<secret>` — then `AE_TOKEN` must
  match it (constant-time) or the run is rejected (fail-closed, CWE-306/#35).
  Without `AE_TOKEN_EXPECTED`, the legacy behavior holds: any non-empty
  `AE_TOKEN` (or none) is accepted. Dev/offline runs are unaffected. The engine
  still does NOT gate its own deploys — see issue #2.
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
- `--max-steps N` — cap on how many steps the orchestrator may autonomously
  decompose; if the plan exceeds N, `orchestrator.run` aborts the run before
  any codegen (the decomposition analogue of `--max-tokens`). Guards against an
  unbounded LLM plan — runaway scope and unbounded LLM/hardware cost. Default
  off. (Autonomy-safety bound; distinct from the reserved deploy-gating fork
  in issue #2.)
- `--kb[=DIR]` / `--kb-max-lines[=N]` — knowledge ledger path and injection cap
- `--kb-stats` — read-only inspector: print a category breakdown of the
  `--kb` ledger (total / deployed / failed / critic-rejected / health / batch /
  other, plus the latest line) and exit 0 without running the engine. Off by
  default. Used by `knowledge.printStats`; this is the §30/§24 observability
  surface for what the autonomous loop has actually learned (a co-owner or audit
  can read it without triggering a run). No `--kb` path, or an empty/absent
  ledger, prints a clear "nothing to summarize" line and exits cleanly — it
  never errors on a missing ledger.
- `--tasks FILE` — batch mode: run each non-comment, non-blank line as an
  isolated engine cycle and aggregate the autonomy-health report (see
  `loop.zig`).
- `--report[=FILE]` — write the machine-consumable JSON health report (see the
  run-report note below). `--health-hook <CMD>` runs `<CMD> <report>` after an
  unhealthy run (or always with `--always-hook`), so an external gate (CI, a
  co-owner deploy policy) can consume the verdict without the engine
  implementing the gate. The hook is spawned with a real-allocator `Threaded`
  io (the global single-threaded io's allocator is `.failing` and OOMs on
  spawn — same trap as `evaluator.runTo`); a hook failure is logged, never fatal.

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
- **Honest checkpoint signal (§30):** `deploy.run` returns `!bool` — `true` only
  when the artifact was actually committed to the isolated repo. `engine.run`
  increments `ctx.deploys` **only** on `true`, so a git failure (unavailable,
  or a non-"nothing to commit" commit error) honestly reports `no deploy` in the
  health verdict instead of a false-green deploy. An unchanged artifact
  (re-run in the same workdir) is `nothing to commit` on **STDOUT** (stderr is
  empty) — `deploy.run` treats that as `true` (idempotent, already checkpointed).
  **Do NOT "simplify" `deploy.run` back to `_ =` + unconditional `ctx.deploys += 1`** —
  that reopens the false-green signal.
- **Gotcha — deploy spawns git through a real-allocator io.** Like
  `evaluator.runTo`, `deploy.run` must NOT use `ctx.io` (global single-threaded,
  `.failing` allocator → OOM on the child argv/env arena). It spawns git via a
  per-call `std.Io.Threaded.init(ctx.allocator, .{ .environ =
  std.Io.Threaded.global_single_threaded.environ.process_environ })` — the real
  OS environ, not `ctx.environ` (tests set it to `.empty`, which would break
  git's PATH/HOME resolution).
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
outcome (deployed/failed) plus degradation counters (critic_rejections, mock_fallbacks, token_budgets_exceeded, max_steps_exceeded); step count, deploys, retries; the orchestrator
prepends prior lessons to its decomposition prompt so later runs avoid
repeating failures. Opt-in and off by default (`Ctx.kb_path = null`): with
`--kb` unset no file I/O occurs and every existing test/pipeline path is
unchanged. The mock backend ignores injected context, so prompt shape never
affects mock output (and the engine test stays green).
Critic `REJECT` reasons are persisted too (`knowledge.recordCritic`), so
future decompositions can steer away from the rejected shape — not only the
numeric `critic_rej=N` counter that `recordLesson` records.
- **Lesson dedup (feat):** the KB ledger now writes via `store.appendUnique` instead of `store.save` for the four recorders (`recordLesson`/`recordCritic`/`recordHealth`/`recordBatch`). `appendUnique` skips a new lesson when an identical line already exists on disk, so a recurring failure/critic/health lesson is recorded once, not re-accumulated every run; under `--kb-max-lines` that freed slot is spent on *distinct* lessons rather than duplicates. `store.save` stays the plain-append primitive (tests use it directly). No new flag.
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

`Ctx` carries seven autonomy-health counters incremented at their event sites:
critic_rejections, mock_fallbacks, retries (self-correction rebuilds), deploys,
network_retries (recovered HTTP retries from `http.complete`),
token_budgets_exceeded, and max_steps_exceeded (set when `--max-steps` aborts
the decomposition — distinct from a generic failure). `monitoring.report` emits
them alongside events/tokens
so the loop can read its own effectiveness (critic reject rate, mock-fallback
frequency, retry churn, deploy rate) without parsing event strings.
`network_retries` is observability-only: a recovered transient network blip is
NOT a degradation, so it never trips `assessHealth` (unlike `mock_fallbacks`).
`llm/http.zig` is the only network path and the only place that shells out
(via `std.process.run`). It invokes `curl` with **array argv** (never a shell),
so `url`/`body`/`key` are passed positionally and cannot inject shell
commands — do NOT "simplify" this to a `sh -c`/string-command invocation.
- **Critic static denylist is substring-based, not exact tokens (security).** `critic.dangerous()` matches `std.process`, `@cImport`, `@import("c")`, `asm`, `@export` as *substrings*, not the exact `std.process.Child` token. Reason: indirection like `@field(std.process, "Child")` or `std.process.spawn` contains `std.process` but not `std.process.Child`, so an exact-token match is a real bypass that let malicious code reach the evaluator/deploy. None of these substrings appear in the mock backend's benign step output, so the green deploy path is unaffected. Do NOT "simplify" this back to exact tokens — that reopens the bypass. The denylist runs per-fragment (step.build) and is deterministic (no LLM call); re-scanning the merged artifact is redundant (tokens are a union of fragments) and intentionally avoided.
`jsonEscape` escapes the full RFC 8259 control range (U+0000–U+001F) because
the prompt path carries semi-trusted input (KB lessons, recorded evaluator
errors, task text) that can contain raw control bytes; an unescaped one
yields malformed JSON → server rejection → silent mock fallback.
`monitoring.writeReport` + `--report[=FILE]` emit a machine-consumable JSON
run report (single `TaskResult`, or `tasks[]` + `batch_healthy` for `--tasks`),
reusing the `assessHealth` verdict. `main` exits `1` when the verdict is
unhealthy (mock default stays exit 0). This is the engine reporting its own
health — it does NOT implement the issue #2 deploy-gating fork; it only makes
`TaskResult.verdict` carries the machine-readable reason (dup of
`assessHealth.verdict`) so a gate can branch on *why*, not just the boolean.
The JSON result also exposes `tokens` (real LLM spend) and
`max_steps_exceeded` (plan-cap aborts) as structured fields, alongside the
counters, so an external gate sees cost + plan-cap signals without parsing logs.

## Tooling caveat: no CodeGraph in this harness
The autonomy charter (§4/§5) assumes a CodeGraph instrument. This project's
harness exposes **no CodeGraph tool** — substitute `ast_grep` (structural),
`grep` (call sites), `lsp` (references/definition), and `glob` (layout) for the
graph passes the charter describes. Re-sync the mental graph after every
structural change by re-reading the touched modules; don't assume a stale
module map. Do NOT waste a cycle searching for a `codegraph` tool.

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
- **Test hermeticity: never reuse a fixed `/tmp` workdir across runs.** Engine
  tests that checkpoint into git (`deploy.run`, `recovery_test`, `plan_gate_test`,
  `ledger_test`) use fixed `/tmp/yuxi_*` dirs. A leftover `.git` from an
  assistant's earlier direct binary run collides with the test's `git init` /
  commit and yields cryptic `error: invalid object 100644 ... for 'gen_final.zig'`
  — a false FAIL that looks like a product bug. Either `deleteTree` the dir at the
  start of each test (preferred: `defer std.Io.Dir.deleteTree(..., base) catch {}`)
  or use a unique timestamped dir. Always clean `/tmp/yuxi_*` before a full
  `zig build test`; the suite does NOT self-clean those paths.
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
- **Gotcha — engine does not create its workdir.** `engine.run` writes
  `gen_*.zig`/`gen_final.zig` into `ctx.workdir` but never `mkdir`s it; a
  deploying run only succeeds if the workdir already exists (deploy.run's
  `ensureDir` runs *after* the builder writes). A CLI test (or any caller)
  that shells a deploying run with a custom `--out` MUST `fs.ensureDir` the dir
  first, or the first builder write fails with `FileNotFound` and the run
  exits 1. The default `ae_out/` only "works" because a prior run left it
  behind — do not rely on that. (`main_test` now isolates `--out` + ensureDirs
  it for the `--expect` e2e test.)
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
- `feat`: machine-consumable run health report — `monitoring.writeReport` +
  `--report[=FILE]` emits JSON (`TaskResult` / `tasks[]`+`batch_healthy`), and
  `main` exits 1 on an unhealthy `assessHealth` verdict (mock default stays 0).
  Closes the §30 runtime-feedback visibility gap without building the issue #2
  deploy-gating fork. Also split `knowledge/knowledge_test.zig` (202 SLOC, §8)
  into `store_test.zig` + `ledger_test.zig`, and restored dropped `--record` /
- `feat`: run report now carries the verdict reason — `monitoring.TaskResult`
  gained `verdict: []const u8` (owned dup of `assessHealth.verdict`);
  `writeReport` emits `"verdict":"…"` so a gate branches on *why* a run is
  unhealthy, not just the boolean. `monitoring.taskResult` centralizes the
  borrow→own dup; added a `writeReport` shape test (incl. JSON-breaking quote
- `fix`: keep the LLM API key out of the process table (CWE-214) — `http.complete`
  now writes the bearer header to a `0600` temp config and passes it to curl
  via `-K` instead of an `-H` argv element; added a regression test.
- `feat`: external health gating via `--health-hook <CMD>` (fires `<CMD>
  <report>` on an unhealthy run, or always with `--always-hook`). Consumes the
  machine-readable report so a CI/co-owner gate can act on the verdict without
  the engine implementing the gate (issue #2 fork still NOT built). Spawns via a
  real-allocator `Threaded` io (the global single-threaded one OOMs on spawn);
- `fix`: `main` now exits 1 on a CLI parse error (missing `--task`, unknown
  flag) instead of `catch return` → exit 0. `--help` still exits 0. This
  protects the §30 exit-code contract (CI/cron gate on process status from
  #18/#19/#21): a malformed invocation must not look like a healthy run.
- `feat`: build-time version stamp + `--version`. `build.zig` runs `git describe
  --tags --always --dirty` and injects it as `build_options.version` into every
  module (no hand-maintained `version` constant, preserving the tag-based
  convention). `--version`/`-V` prints `yuxi <tag>` and exits 0 (same success
  contract as `--help`); `monitoring.writeReport` now emits a top-level
  `"version"` envelope field so an external gate can compare engine versions
  across deploys. `main_test` shells the binary to assert the `yuxi v…` stamp;
  `config_test` proves `--version`/`VersionRequested` is reachable. CI checkout
- `fix`: offline replay now degrades to `mock` on exhaustion instead of
  hard-failing the whole offline/CI run (`transport.complete` catches
  `error.ReplayExhausted` and falls back to `mockComplete`, incrementing
  `ctx.mock_fallbacks`). A shorter-than-needed transcript (a retried attempt,
  a regenerated step, a longer plan) no longer breaks the engine's own offline
  test path; a genuinely empty replay still logs the gap. `transport_test`
  asserts the fallback. Also synced README + `--help` with the v0.3.0 flag
  surface (`--report`, `--health-hook`, `-V/--version`, `--tasks`, CWE-214).
- `consult`: issue #2 (deploy-gating fork) surfaced on the issue, NOT built —
  framed Options A (dry-run/plan mode), B (--hitl deploy gate), C (external
  policy hook) and deferred to the co-owner. The report + health-hook plumbing
  it would consume is already merged (v0.3.0).
- `feat`: cap autonomous plan size with `--max-steps` (PR #26, merged at
  `e54b0b0`). `config.parse` → `Config.max_steps` → `Ctx.max_steps`
  (wired in `engine.newCtx`) → guard in `orchestrator.run`: if the LLM plan
  exceeds N, the run aborts before codegen/build/deploy (decomposition
  analogue of `--max-tokens`). Autonomy-safety bound; off by default. Does
  NOT touch the reserved issue #2 deploy-gating fork. New `orchestrator_test`
  + `config_test` coverage; CLI smoke confirmed abort (no deploy, exit 1) vs
  normal deploy with a generous cap.
- `fix`: `--max-steps` abort was misread as a generic unhealthy cycle (it
  emitted only the `no deploy; ` verdict), polluting the next cycle's KB
  steering (PR #27, `8c23a2b`). Mirrored the `token_budgets_exceeded`
  pattern: added `Ctx.max_steps_exceeded`, incremented it on the
  orchestrator abort, and gave `assessHealth` a distinct `max-steps
  exceeded; ` verdict clause + WARN line. `orchestrator_test` now asserts
  the counter; CLI smoke confirms the distinct WARN + exit 1.
- `note`: carry-over items from prior cycle summaries are already landed on
  master — `ci.yml` already sets `fetch-depth: 0` + `fetch-tags: true`
- `fix`: `recordLesson` omitted `max_steps_exceeded` (the distinct counter PR
  #27 added to the verdict), so a `--max-steps` abort was surfaced in health
  but NOT persisted to the KB — the next run's `injectPrompt` stayed blind to
  an aborted decomposition (PR #28, `099ffc1`). Mirrored the
  `token_budgets_exceeded` field in both lesson formats + doc comment;
  `ledger_test` now asserts `max_steps_ex=1`. Also corrected the AGENTS.md
  "six counters" note to seven and added `max_steps_exceeded` to the KB
  feature list so the bootstrap matches the source.
  (verifies `--version` via `git describe` works in CI), and the replay
  mock-fallback fix shipped in PR #25. Don't re-attempt either.
- `merge`: PR #20 (CWE-214, `18d83b4`) — the LLM key-out-of-argv security fix
  was actually still OPEN on `fix/llm-key-out-of-argv`, despite prior cycle
  summaries claiming it merged into v0.3.0. Verified checks green (Kilo + build-
  and-test), merge-clean, merged via `gh pr merge --squash --delete-branch`.
  Corrected CHANGELOG v0.3.0 (it falsely listed #20; #20 postdates the tag) and
  added a v0.4.0 section covering #20/#24/#25/#26/#27/#28. Release v0.4.0 cut
  from `18d83b4` (CI green).
- `lesson (release-scope verification)`: a prior autonomous cycle's summary
  falsely reported a merge that never happened, and the claim leaked into the
  CHANGELOG v0.3.0 section. Before asserting "shipped in release X", verify
  against git ancestry, not summary prose: `git merge-base --is-ancestor
  <commit> <tag>` and `git grep <symbol> <tag> -- src` are ground truth for
  release contents. Treat a cycle-summary "merged" claim as untrusted until the
  PR state (`gh pr view`) + tag tree confirm it.
- `fix(knowledge)`: bound the KB ledger on write (#29, `3049e8f`). `save`
  appended without limit while only `tailLessons` bounded injection, so a
  long-running autonomous engine grew the ledger forever and reloaded it in
  full each run. `save` now enforces `--kb-max-lines` on write (null = prior
  unbounded default). Extracted `load`/`save`/`tailLessons` into
  `knowledge/store.zig`; `knowledge.zig` 203→122 SLOC (was a §8 breach) and
  `knowledge/` stays at 4 files (≤5 §8). Re-exported `load`/`save` so callers
  are unchanged. Regression tests for bounded + unbounded save. Merged via
  squash; build-and-test green.
- `note`: CI shows a Node.js 20 deprecation annotation (actions/checkout@v4,
  mlugg/setup-zig@v2 forced onto Node.js 24). Not a failure; track as a future
  workflow-maintenance item, don't block merges on it.
- `feat`: wall-clock autonomy cap `--max-time N` (seconds) (`3049e8f`→Unreleased).
  Bounds a single engine.run to N seconds, aborting fail-closed on overrun
  (ref #26's `--max-steps` theme: unattended runs must not stall forever on a
  hung build/eval/deploy). Plumbing mirrors `--max-steps`/`--max-tokens`:
  `config.parse` (seconds→ms) → `Ctx.max_time_ms` → `engine.newCtx`; a
  monotonic-clock check (std.os.linux.clock_gettime, CLOCK.MONOTONIC) at the
  self-correction loop in `engine.run` increments `ctx.run_time_exceeded`
  and returns `finishRun` (no deploy). `monitoring.assessHealth` emits a
  distinct `wall-time exceeded; ` verdict clause + JSON field. Tests:
  `config_test` (`--max-time 2`→2000ms) + a new `plan_gate_test` engine-run
  abort (zero cap → `run_time_exceeded==1`, verdict in KB). Off by default.
  Does NOT touch reserved issue #2 deploy-gating fork. Note: this Zig 0.16
  lacks `std.time.Timer`/`nanoTimestamp`; wall-clock uses
  `std.os.linux.clock_gettime` + `std.os.linux.timespec` (sec/nsec), which
  is fine since the repo already targets Linux (knowledge/fs use
  std.os.linux too).
- `refactor(core)`: extract run-lifecycle tail (finishRun + flushRecord) into
  `core/runlife.zig` (b6cda67). `--max-time` (#30) pushed engine.zig to 229
  SLOC, a §8 >200 breach; moved the LAYER 7-9 resilience/knowledge/monitoring
  tail + record flush out, dropping engine.zig to ~180 and keeping core/ at 5
  top-level files (§8 OK). engine.run now calls runlife.finishRun /
  runlife.flushRecord; build.zig registers `runlife` in the all-to-all DAG.
  No behavior change. Lesson: after adding a feature, re-check the §8 SLOC
  ceiling — a feature that fits today can push a file over 200 once combined
  with prior edits; extract a cohesive subtree rather than splitting arbitrarily.
- `feat`: self-correction retry cap `--max-attempts N` (Unreleased, see PR #31).
  The build/eval loop was hardcoded to 3 attempts in engine.zig; now
  operator-tunable — the 4th autonomy cap after --max-steps/--max-tokens/
  --max-time. `Ctx.max_attempts` (`?usize`, null→3) → `config.parse`
  (`--max-attempts N`) → `engine.newCtx` → attempt loop bound
  (`ctx.max_attempts orelse 3`). NOT a fail-closed safety abort (unlike the
  other three caps): exhausting retries is the normal "nothing deployed"
  outcome, so it reuses the existing health-verdict path (no new
  `attempts_exceeded` clause). Tests: config_test (`--max-attempts 5`→5, null
  default) + plan_gate engine-run test (`max_attempts=1` stops after one
  attempt, no deploy). Off by default. Smoke-confirmed: `attempt 1/1` with the
  flag, `attempt 1/3` without.
- `fix`: `--tasks` batch KB ledger honors `--kb-max-lines` (a13d322, #32). `recordBatch` ignored the operator's cap (called `store.save(.., null)`) while its per-run siblings threaded `kb_max_lines` — a long-running `--tasks` engine set to a cap still grew the ledger unbounded on the batch path, reopening the #29 hole. Wired `cfg.kb_max_lines` through `loop.runTasks`; added a regression test (ledger_test 9/9). CI green, merged squash.
- `ec2f8fa` fix(deploy): `deploy.run` reports a real checkpoint status (`!bool`) instead of swallowing git results; `engine.run` only counts `ctx.deploys` on a real commit. Two latent bugs exposed by honoring the result and fixed: (1) `deploy.run` spawned git through `ctx.io` (`.failing` allocator → OOM, same trap as `evaluator.runTo`) — now a per-call real-allocator `Threaded` io with the OS environ; (2) git prints `nothing to commit` to STDOUT (empty stderr) on an idempotent re-run, so the commit check now scans both streams. Also restored `src/evaluator/evaluator.zig` to the `build.zig` test list (prior cycle had dropped it) and made the recovery tests hermetic (clean workdir at start) so a leftover `.git` can't poison the checkpoint. All 18 test roots green, `zig fmt --check` clean. CI green. Landed directly to master (no PR per cycle-owner decision).
- `feat(observability)`: `--report` JSON exposes `tokens` + `max_steps_exceeded` (39a36e8, #33). Merged, not yet tagged (§28).
- `test(§21)`: `--expect` end-to-end CLI test in `main_test` shells the built binary (3e1a6a1, #34). Merged, not yet tagged (§28).
- `d8c072c` feat(observability): `--kb-stats` read-only knowledge-ledger inspector (#40). The autonomous loop records rich lessons (deployed/failed runs, critic rejections, health, batch) to the KB ledger, but there was no way to see what it had learned without running a cycle or parsing raw lines (§30/§24 gap). `--kb-stats` loads the configured `--kb` ledger and prints a category breakdown (total / deployed / failed / critic-rejected / health / batch / other + latest line), then exits 0 without running the engine. `config.parse` short-circuits the missing-task check; `main` calls `knowledge.printStats`. Categorization core `knowledge.summarize` is a pure function with two direct unit tests. With no `--kb` path or an empty/absent ledger it prints a clear "nothing to summarize" line and exits cleanly — never errors on a missing ledger. Also added a test-hermeticity gotcha to this file (fixed `/tmp` workdirs collide across runs on the Android overlay fs). CI green (build/test/fmt), merged squash.






Resolved (no longer open): issue #1 (gateway rate-limit no-op) — the dead
per-call counter was removed in `dc7f217`; gateway now does auth + validation
+ PII redaction only. Closed as *remove* (option B).

- `e48c290` docs(agents): record #33/#34/#35 in Recent-cycles, mark merged (#36).
- `caa8c7f` fix(security): critic denylist matches dangerous substrings (`std.process`, `@cImport`, `@import("c")`, `asm`, `@export`) closing an indirection bypass (CWE-265) — exact-token match let `@field(std.process,"Child")`/`std.process.spawn` reach eval/deploy; mock path unaffected (#37, released v0.5.1).
- `419a9e9` feat(knowledge): deduplicate identical lessons in the KB ledger via `store.appendUnique` (4 recorders switched); recurring failure/critic/health lines recorded once, distinct lessons preserved under `--kb-max-lines` (#38).
Tracked for next-cycle / co-owner input: **generated-code runtime sandbox (defense-in-depth).** The critic denylist blocks `std.process`/`@cImport`/`asm`/`@export` *text*, but an accepted step still compiles and runs as a native binary with the engine's full OS privileges (`evaluator.runTo` spawns `bin_path` against the real environment). A generated step could use `std.fs`/`std.net` to read, tamper, or exfiltrate arbitrarily. Next step is a deliberate sandbox design (landlock/seccomp on Linux, or an explicit syscall allowlist) — a product-shaping + security-boundary fork worth a co-owner read before committing direction. Not a quick patch.
- `feat(observability)`: compose the `--kb-stats` ledger summary into the `--report` JSON (§12/§13) so a §30 gate reads what the loop has learned from the same document it already consumes for autonomy-health. `report` field is a new top-level `"kb_stats"` object (or `null` when `--kb` is unset), so existing `--health-hook` consumers are unaffected; it shares the pure `knowledge.summarize` + `knowledge.load` primitives already exercised by #40. To stay under the §8 200-SLOC cap, the report's KB-stats emitter + the shared `escapeJson` moved out of `monitoring.zig` into a new `src/monitoring/report_kb_stats.zig` (registered in `build.zig`; `monitoring.escapeJson` is now a thin re-export). Regression test in `monitoring_test.zig` covers both the `null` and populated-ledger shapes and asserts the emitted counts equal `knowledge.summarize`.

