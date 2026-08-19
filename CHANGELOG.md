# Changelog

All notable changes to the Yuxi engine are recorded here. Entries group the
tracked history by capability; commit hashes reference `git log`.

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

## Engineering

- **Resilience state per-run** — `808a469`. `failures` moved from a module-level
  global onto `Ctx` so each run tracks its own count.
- **Repo hygiene** — `15cedc5` moved `AGENTS.Style.md` into the repo so it
  co-locates with `AGENTS.md`; `DESIGN.md` and `README.md` document the current
  pipeline.

## Repository

- **CI fixed** — `.github/workflows/ci.yml` referenced a nonexistent action
  slug (`goto-bus/setup-zig`); switched to the maintained `mlugg/setup-zig@v4`
  so the Zig 0.16.0 toolchain actually installs and the build/test/format
  gates run on push and PR.
