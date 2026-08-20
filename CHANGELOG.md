# Changelog

All notable changes to the Yuxi engine are recorded here. Entries group the
tracked history by capability; commit hashes reference `git log`.
### Features
- `feat`: plan-quality critic gate. `engine.run` now reviews the orchestrator's
  decomposition *before* codegen (LAYER 2.5). `critic.reviewPlan` reuses the
  critic transport + verdict parser with a plan-specific prompt; on REJECT it
  increments `critic_rejections`, persists a `knowledge.recordCritic("plan", …)`
  lesson, logs `engine: ABORT at plan critic`, and returns before any codegen
  or deploy. Always-on, fail-fast, non-breaking — the default backend returns
  APPROVE. New `src/core/selfcorr/plan_gate_test.zig` exercises the reject
  path end-to-end via the `Ctx.llm_fn` seam. Resolves §14 feature-bias drift
- `fix`: plan-reject no longer truncates the learning loop. The LAYER 2.5
  plan critic gate in `engine.run` aborted with a bare `return`, skipping
  LAYER 7-9 (resilience summary, `knowledge.recordLesson` with `critic_rej=N`,
  `monitoring.report` + `recordHealth`). A rejected plan therefore never wrote
  its numeric critic-rejection counter to the KB ledger and never persisted a
  health verdict, so the next cycle's `injectPrompt` couldn't steer away from a
  plan-shaped failure — contradicting the gate's own purpose. The four early
  aborts (gateway, orchestrator, plan critic, no-verify) now tail-call a new
  `finishRun` helper that runs LAYER 7-9, so every exit path records outcome +
  health. `engine.fileExists` moved to `util/fs.zig` to keep `engine.zig` under
- `fix`: `builder.run` now increments `ctx.mock_fallbacks` when it falls back
  to the mock backend after a transport error. It already called
  `resilience.fallback(ctx)`, but unlike the per-step critic fallback in
  `step.zig` it never counted the fallback — so the autonomy-health signal
  (`monitoring.assessHealth`'s "mock fallback dominated" WARN) and
  `knowledge.recordLesson`'s `mock_fb=N` counter under-counted builder-level
  fallbacks, letting a mock-dominated cycle slip past the health check. The
  fallback path now increments `ctx.mock_fallbacks`, so the signal fires
  regardless of where the fallback originated. New `src/builder/builder_test.zig`
- `refactor`: `monitoring.assessHealth` is now the single source of truth for
  cycle health. It returns `HealthVerdict { verdict, healthy }` (caller-owned
  verdict). `loop.runTasks` previously computed its own `healthy` as
  `deploys > 0 and token_budgets_exceeded == 0`, which *ignored* the
  `mock_fallbacks > deploys` WARN that `assessHealth` emits — so a batch report
  could say `health=OK` for a cycle whose per-run verdict (persisted to the KB
  by `engine.finishRun`) said `mock fallback dominated`. The loop now calls
  `assessHealth` and prints the verdict per task, so the batch summary and the
  KB can never disagree about health. `engine.finishRun` updated to the struct
- `feat`: bounded knowledge-base injection via `--kb-max-lines[=N]`. The KB
  ledger (`knowledge.save`) is append-only and `injectPrompt` previously loaded
  the *entire* file into every decomposition prompt, so a long-lived engine's
  prompts bloat unbounded (context cost, truncation risk). `injectPrompt` now
  caps the prepended lessons to the last N lines via `tailLessons`; N defaults
  to 200 when `--kb-max-lines` is given without `=N`. Null by default (no cap) —
  identical to historical behavior, so all existing pipelines/tests are
  unchanged. New tests in `src/knowledge/knowledge_test.zig` cover both the
  capped and uncapped paths.




### Engineering / observability
- `refactor`: removed dead code in `src/gateway/gateway.zig` — the no-op
  per-process rate-limit (the counter could never exceed 1 in the single-shot
  CLI) and the unused `intent` variable. Resolves co-owner fork #1 as *remove*.
- `fix`: `engine.run` no longer logs `"task pipeline complete"` on paths that
  deploy nothing; the completion line now reflects the actual outcome
  (deployed vs not).
- `fix`: `gateway.run` previously computed the PII-redacted task and then
  discarded it (`defer free`, returned only `bool`) — so the sanitizer was a
  silent no-op and the orchestrator + KB ledger ran on the *raw* task. It now
  returns the owned redacted slice; `engine.run` uses it for `orchestrator.run`
  and `knowledge.recordLesson` and frees it. Denial (short task / empty
  `AE_TOKEN`) returns `null` and nothing runs. New `gateway_test.zig` covers
- `fix`(security): the redactor still leaked email domains. `redact` only
  replaced the `@` glyph and swallowed the rest of the @-run, so
  `user@corp.com` became `user<redacted>corp.com` — the domain stayed visible.
  `redact` now replaces the entire whitespace-delimited token containing `@`
  (`user@corp.com` -> `<redacted>`), preferring over-redaction at the trust
  boundary. `gateway_test.zig` now also asserts the whole-email token is
  removed and a non-PII task passes through unchanged.

### Knowledge base / batch learning loop
- `feat`: `--tasks` batch runs now persist an aggregate autonomy-health
  summary to the KB (`knowledge.recordBatch`: tasks, total deploys, unhealthy
  count). Per-run `recordLesson`/`recordHealth` already wrote one line per
  `engine.run` cycle; this closes the gap so the next run's `injectPrompt`
  also steers away from an *unhealthy batch shape* (e.g. every task
  mock-fell-back, none deployed), not only from a single cycle's verdict.
  No-op when `--kb` is unset or the batch is empty. New `knowledge_test.zig`
  unit test + `loop_test.zig` integration test cover it.
### Test suite now runs (issue #3, corrected)
- `fix`: `zig build test` now *executes* the test suite. The first issue #3
  landing made every test file its own `addTest` root (correct), but the test
  step depended only on the `addTest` **compile** step — so `zig build test`
  compiled every root and exited 0 while **no test ever ran** (a silent
  false-green that persisted into CI). The fix wraps each `addTest` with
  `addRunArtifact` and depends on the **run** step, so a failing test now fails
  the build. The module-name import refactor (all `@import` paths → names) plus
  per-file test roots landed earlier. That refactor surfaced and fixed latent
  Zig 0.16 `std.Io` API mismatches the vacuous suite had hidden: `file.close(io)`
  (1-arg), `w.interface.writeAll` + `w.flush()`, `_ = std.os.linux.close(fd)`,
  `var frags` slice coercion in the compose test, and complete `config.Config`
  literals (added `--kb`/`--replay`/`--record` fields).
- `chore`: the full suite is slow on this environment (~20-40s/root, each root
  recompiles its module graph) — CI must allow the wall time; don't shrink
  `test_files` to fit a tighter timeout.
- `fix`: the engine integration test now actually deploys. Two Zig 0.16
  runtime traps were masked by the vacuous suite and then by the IPC hang:
  (1) `evaluator.runTo` must spawn `zig` with a real allocator *and* the real
  OS environment — `ctx.io` (`global_single_threaded`) has a `.failing`
  allocator (OOM on argv) and a default `Threaded` has an *empty* environ
  (child `zig` dies with `AppDataDirUnavailable`). `runTo` now builds a per-call
  `Threaded.init(ctx.allocator, .{ .environ = global_single_threaded.environ.process_environ })`.
  (2) On aarch64 the default `addRunArtifact(tt)` selects the `zig_test` server
  protocol whose pipe deadlocks when the engine test spawns children, so the
  build hung forever. Test binaries now run **directly** (`Step.Run.create` +
  `addArtifactArg(tt)` + `stdio = .inherit`, no `--listen`).
- `test`: the evaluator unit test (`evaluator.run gates deploy on compile+run`)
  was itself broken — invalid Zig in the `spec` fixture (missing `std` import /
  missing `w.flush()` left an empty file), a bare `ctx.allocator.free(e)` that
  double-freed `eval_error`, and `std.testing.allocator` reporting the
  intentional exit-time `ctx.events`/`eval_error` as leaks. Switched to absolute
  `/tmp` fixture paths, `clearEvalError()`, and `page_allocator`. All 13 test
- `refactor`: `engine.compose` extracted to `src/core/compose.zig` (`compose.merge`),
  bringing `engine.zig` back under the 200-SLOC hard invariant (§8) and freeing
  `core/`'s 5-file cap. The compose unit test moved with it; `build.zig` registers
  `compose` as a named module and adds it as a 14th test root.
- `feat`: the autonomy-health verdict now closes the learning loop. `monitoring.assessHealth`
  returns the accumulated verdict (e.g. `no deploy; self-correction exhausted; `)
  instead of only logging it; `engine.run` persists it to the KB via the new
  `knowledge.recordHealth` on an unhealthy cycle, so a later run's `injectPrompt`
  also steers away from an *unhealthy cycle shape* (mock-dominated, budget-exhausted)
  — not only a fixed failure or a rejected step (`recordLesson` / `recordCritic`).
  A healthy cycle writes no health lesson. New unit tests in `monitoring_test.zig`
  (asserted verdict) and `knowledge_test.zig` (persist + no-op).

### Knowledge base: durable critic lessons (feat)
- `feat`: the KB now persists **qualitative critic-rejection reasons**, not just
  the numeric `critic_rej=N` counter. When a critic `REJECT`s a step,
  `knowledge.recordCritic` appends `- critic rejected "<step>": <reason>` to the
  KB; `injectPrompt` already prepends the whole KB to future decomposition
  prompts, so the loop now steers away from rejected shapes across runs. New
  `recordCritic` unit test plus an end-to-end assertion in `recovery_test.zig`
  (the reject→regenerate→approve branch) that the reason lands in the KB.


### Knowledge base: failed-run error captured (feat)
- `feat`: `knowledge.recordLesson` now appends a trimmed `error="…"` snippet
  when a run fails (`ctx.deploys == 0`) and `ctx.eval_error` is set, so the next
  run's injected lessons explain *why* a prior run failed — not just the numeric
  `failed` outcome. Closes the learning loop for non-critic failures too
  (complementary to `recordCritic`'s qualitative critic reasons). New unit test
  in `knowledge_test.zig`.
## v0.1.0 (2026-08-19)

First tagged release of the Yuxi (玉溪) autonomous software-evolution engine,
covering the core pipeline plus the knowledge base, offline record/replay, and
batch-task capabilities shipped through commit `6309478`.

### Core pipeline
- Gateway → orchestrator (decompose) → builder/critic (per step) → compose → evaluator → deploy.
- Self-correction: build → compose → evaluate retries up to 3×, feeding compiler/run `stderr` back to the builder.
- Critic feedback loop: a `REJECT` regenerates the rejected step with the critic's reason; resilience fallback is last resort.
- Resilience + monitoring: per-run health assessment and degradation counters (retries, critic rejections, mock fallbacks, token-budget breaches).

### Knowledge base (`--kb`)
- Persistent, replayable lesson ledger; prior lessons are injected into the decomposer prompt and each run's outcome plus counters are recorded, closing the learning loop.

### Offline + batch
- `--replay[=FILE]`: drive the real `.openai`/`.local` dispatch offline from a recorded transcript (no API key, no network) for CI/tests.
- `--record[=FILE]`: capture every real LLM response as a `--replay`-compatible transcript — record once, replay forever.
- `--tasks FILE`: batch mode running N tasks with isolated workdirs.
- `--cache[=DIR]`: incremental on-disk LLM-response cache.
- `--expect TEXT`, `--max-tokens N`: behavioral verification and a soft token-budget ceiling.

### Engineering
- Engineered to Zig 0.16; hard invariants (≤5 files/dir, ≤200 SLOC/file, deep nesting) enforced.
- CI green on push/PR: `zig build`, `zig build test`, `zig fmt --check src`.
- Integration tests: self-correction recovery, critic denylist block (§19 security gate), token-budget abort, and the record→replay round trip.

### Known open questions (co-owner forks)
- #1 gateway rate-limit is a no-op — enforce or remove.
- #2 `--dry-run`/plan-mode and `--hitl` approval gating scope.

## Pipeline capabilities

- **Self-correction (build+eval feedback)** — `7fbfc5e`. The pipeline retries
  build -> compose -> evaluate up to 3 times; the compiler/run `stderr` is
  stored on `ctx.eval_error` and fed back to the builder so the LLM can fix
  code that fails to compile or run.
- **Critic feedback loop** — `7583b77`. `critic.run` returns `Verdict{ok,reason}`;
  a `REJECT` regenerates the rejected step with the critic's reason as builder
  feedback instead of downgrading the whole backend. `resilience.fallback` is now
  a last resort after the guided retry still fails.
- **Critic denylist** — `5e9515e`. Fast-path rejects `std.process.Child` and
  `@cImport(` before the LLM critic call, returning an owned reason.
- **Evaluator compile+run** — `e47b00b`. The evaluator compiles and runs the
  composed artifact (not a per-file ast-check) and gates deploy on success.
- **Composition** — `03f8ffc`. N steps compose into one runnable `gen_final.zig`.
- **Intermediate cleanup** — `6de7ed2`. `gen_*.zig` removed after a successful
  deploy; only `gen_final.zig` is committed.
- **Incremental LLM cache** — sha256-keyed on-disk response cache
  (`util/cache.zig`); `--cache[=DIR]` enables it.
- **Transport JSON escapes** — `468a77d`. `extractContent` unescapes
  `\n \t \r \b \f` from OpenAI-style responses.

- **Behavioral verification (`--expect`)** — the evaluator compares a clean run's
  trimmed stdout against a caller-supplied spec; a mismatch sets `ctx.eval_error`
  and drives the existing self-correction loop, upgrading "runs without crashing"
  to "produces the specified output". Child stdout/stderr are captured to a temp
  file (std.process.run's pipe capture was empty in this environment), which also
  fixes previously-blank self-correction error feedback.
- **Injectable LLM backend seam** — `Ctx.llm_fn` lets a test (or future real
  backend) replace the built-in mock/http dispatch in `transport.complete`.
  Used to add an engine-level integration test proving the self-correction
  loop recovers from a broken first build (fail first code-gen, then succeed).

- **Token/cost budget cap** — `feat:` `--max-tokens N` sets a soft ceiling on
  LLM spend (`ctx.max_tokens`); `engine.run` aborts the build loop once
  `ctx.tokens` (counted per completion in `transport.complete`) reaches it,
  recording `engine: token budget exceeded` and deploying nothing. Default off.
- **Autonomy-health verdict** — `1ae73b6`. `monitoring.assessHealth` emits a
  WARN through the event log when a cycle is unhealthy (no deploy, token
  budget exceeded, self-correction exhausted without deploy, mock-fallback-
  dominated), closing the §30/§32 feedback loop on the run-metrics counters
  from `8b62080`. Pure diagnostic: no pipeline behavior change.

- **Run metrics (observability)** — `8b62080`. `Ctx` carries five autonomy-health
  counters — `critic_rejections`, `mock_fallbacks`, `retries` (self-correction
  rebuilds), `deploys`, `token_budgets_exceeded` — incremented at their event
  sites and emitted by `monitoring.report`, so the loop can read its own
  effectiveness without parsing event strings.
- **Batch task execution (`--tasks`)** — `3a16e4d`. `loop.runTasks` runs several
  tasks, each in its own workdir, and prints a health report rather than stopping
  at the first failure.
- **Persistent knowledge base (`--kb`)** — `fac5fa4`. Each run appends one line to
  `<DIR>/lessons`: outcome (deployed/failed) plus degradation counters
  (`critic_rejections`, `mock_fallbacks`, `token_budgets_exceeded`) and step/deploy/
  retry counts. Prior lessons are prepended to the decomposer prompt so later runs
  avoid repeating failures. Off by default (`Ctx.kb_path = null`).
- **Knowledge-base enrichment** — `d1c7cc0`. Lesson lines now carry the degradation
  counters above plus step/deploy/retry counts, so the ledger captures not just
  what failed but how degraded the run was.
- **Offline replay mode (`--replay`)** — `5521d48`. `transport.complete` serves
  recorded LLM responses in call order (file entries split by a line that is
  exactly `---`) when the backend is `.openai`/`.local` and `Ctx.replay_path` is
  set, exercising the real dispatch — including curl auth and response handling —
  offline with no API key, for CI and integration tests. Off by default.
- **Offline record mode (`--record`)** — `74d93fd`. `engine.run` flushes every
  real (non-seam, non-replay) completion into `Ctx.recorded` and writes them as
  `--replay`-compatible entries (delimited by `---` lines), so a single run can
  be replayed through the real `.openai`/`.local` dispatch offline with no API
  key. Closes the record/replay loop.

## Engineering

- **Resilience state per-run** — `808a469`. `failures` moved from a module-level
  global onto `Ctx` so each run tracks its own count.
- **Repo hygiene** — `15cedc5` moved `AGENTS.Style.md` into the repo so it
  co-locates with `AGENTS.md`; `DESIGN.md` and `README.md` document the current
  pipeline.

- **Critic denylist integration test** — `test:` added an engine-level test
  (`engine.run blocks dangerous constructs via critic denylist`) that injects a
  backend emitting `std.process.Child` and asserts the run records
  `critic: rejected (denylist)` and never deploys (`deploy: committed` absent).
  Exercises the §19 security gate end-to-end through the real engine, not just
  the isolated `critic.run` unit test; uses the `Ctx.llm_fn` seam (no network).
- **LLM-critic REJECT recovery test** — `0ea3f5a`. Engine-level integration test
  (`engine.run recovers from an LLM-critic REJECT via regenerate`) injects a backend
  that rejects the first critic call then approves, proving the regenerate-on-REJECT
  recovery branch (step.zig 23-47) via the `Ctx.llm_fn` seam; complements the
  denylist fallback test.
- **Fix: `ensureDir` creates nested parents** — `d759878`. `util/fs.ensureDir` now
  recurses to create intermediate directories, unbreaking `--tasks` per-task
  workdirs (previously `DirCreateFailed`).
- **Fix: mock emits single-line output** — `eef6a4f`. The mock backend now emits a
  single-line function body so `--expect` stdout matches (was tripled by the
  3-step compose).

## Repository

- **CI fixed** — `.github/workflows/ci.yml` referenced a nonexistent action
  slug (`goto-bus/setup-zig`); switched to the maintained `mlugg/setup-zig@v2`
  so the Zig 0.16.0 toolchain actually installs and the build/test/format
  gates run on push and PR.
