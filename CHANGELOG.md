# Changelog

All notable changes to the Yuxi engine are recorded here. Entries group the
tracked history by capability; commit hashes reference `git log`.
## Unreleased

### Engineering / observability
- `refactor`: removed dead code in `src/gateway/gateway.zig` — the no-op
  per-process rate-limit (the counter could never exceed 1 in the single-shot
  CLI) and the unused `intent` variable. Resolves co-owner fork #1 as *remove*.
- `fix`: `engine.run` no longer logs `"task pipeline complete"` on paths that
  deploy nothing; the completion line now reflects the actual outcome
  (deployed vs not).

### Known defect (tracked issue #3)
- `zig build test` executes **0 tests**. Zig 0.16 collects `test` blocks only
  from the root module, so the `src/tests.zig` aggregator silently runs
  nothing. The integration tests listed under v0.1.0 are written but not yet
  executed. Fix: repo-wide module-name imports + per-file `addTest` roots.
  Until landed, a green CI run is NOT proof of behavior.

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
