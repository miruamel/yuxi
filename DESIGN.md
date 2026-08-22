# Yuxi (玉溪) — Autonomous Software Evolution Engine (Zig 0.16)

Developed sketch of the 9-layer agentic loop. Selectable HITL / non-HITL.
The "brain" is an external LLM reached over HTTP (OpenAI-compatible) or a
local server (ollama/llama.cpp); `mock` runs fully offline for dev/test.

## Topology (loop)

```
Gateway -> Orchestrator -> Plan Gate -> (Builder -> Critic)* -> Compose -> Evaluator -> Deploy
                                          ^                          |
                                          \_______ Resilience <- Knowledge <- Monitoring
```

`Monitoring -> Gateway` is the outer autonomous cycle. One task runs a forward
pass. The **Plan Gate** (LAYER 2.5) reviews the orchestrator's decomposition
before any codegen; on `REJECT` it persists a lesson and aborts the run
fail-fast. A rejected `Critic` regenerates that step with the critic's reason as
builder feedback; the `Evaluator` compiles and runs the composed program, and on
failure the pipeline rebuilds (up to `--max-attempts` attempts, default 3) with
the error fed back to the builder (self-correction).

## Layers

1. **Gateway** — auth (optional `AE_TOKEN`), validation, PII sanitizer (whole
   `@`-token redaction), intent router.
2. **Orchestrator** — LLM task decomposer -> numbered `STEP:` plan.
3. **Plan Gate (LAYER 2.5)** — `critic.reviewPlan` reviews the decomposition
   before codegen; `REJECT` persists a critic lesson, logs `engine: ABORT at
   plan critic`, returns before any codegen. Always-on, fail-fast, non-breaking.
4. **Builder** — LLM planner + generator -> writes a `.zig` file. HITL gate
   before write when `mode == hitl`. On transport error falls back to `mock`.
5. **Critic** — fast-path denylist (`panic(`, `std.process`, `@cImport(`,
   `@import("c")`, `asm`, `@export` as substrings) + LLM `APPROVE`/`REJECT`
   with reason; a `REJECT` regenerates the step.
6. **Compose** — merge all step fragments into one `gen_final.zig` with a `main`
   harness that calls each `stepN()`.
7. **Evaluator** — compile **and run** `gen_final.zig`; on failure the error is
   stored and the whole pipeline rebuilds (up to `--max-attempts` attempts) with
   feedback. With `--expect TEXT`, a clean run whose trimmed stdout doesn't
   equal the spec also fails and drives the same self-correction loop
   (behavioral verification).
8. **Deploy** — commit `gen_final.zig` to an isolated git repo in `workdir`;
   intermediate `gen_*.zig` files are removed afterward. Honest checkpoint
   signal: `deploy.run` returns `!bool` — `true` only when actually committed.
9. **Resilience** — per-run failure counter; on LLM transport error, fallback to
   `mock` (increments `mock_fallbacks`).
10. **Knowledge** — persistent lesson ledger (`--kb[=DIR]`). Records per-run
    lessons (deployed/failed, critic rejections, mock fallbacks, token budgets,
    max-steps, wall-time, deploys, retries, step count) and critic `REJECT`
    reasons. `injectPrompt` prepends prior lessons to decomposition prompt
    (capped by `--kb-max-lines`, default 200). `appendUnique` dedups identical
    lessons. `--kb-stats` prints a category breakdown and exits without running.
11. **Monitoring** — single source of truth for cycle health via
    `assessHealth(ctx) -> HealthVerdict { verdict, healthy }`. Emits JSON run
    report via `--report[=FILE]` carrying `TaskResult` (single) or `tasks[]` +
    `batch_healthy` (batch), with `version` envelope and `kb_stats` object.
    External gate via `--health-hook CMD` spawns `CMD <report>` on unhealthy
    runs (or always with `--always-hook`). Process exits 1 on unhealthy verdict.

## Autonomy Safety Caps (all off by default)

- `--max-tokens N` — soft LLM-spend ceiling; aborts build loop when `tokens >= N`
- `--max-steps N` — cap autonomous plan size; aborts decomposition before codegen
- `--max-time N` — wall-clock cap (seconds) per `engine.run`; aborts at loop
- `--max-attempts N` — cap self-correction retries per run (default 3)

## LLM Transport

`llm/transport.zig` dispatches on `Ctx.backend`:
- `mock` — deterministic canned text per role (no network).
- `openai` — `OPENAI_BASE`/`OPENAI_API_KEY` (default `api.openai.com/v1`).
- `local` — `LOCAL_BASE` (default `http://localhost:11434/v1`).

All HTTP backends use `curl` via `std.process.run` with array argv (no shell),
bounded retries (3 attempts, 250ms·n backoff), 60s/10s timeout. Bearer token
written to `0600` temp config, passed via `-K` — never in argv (CWE-214).

## Offline Replay / Record

- `--replay[=FILE]` — serve recorded responses in call order for `.openai`/
  `.local` without network; exhaustion falls back to `mock` (increments
  `mock_fallbacks`). Exercises real backend dispatch offline (CI/tests).
- `--record[=FILE]` — capture every real LLM response into `--replay`-compatible
  transcript (entries delimited by `---` lines). Pair with `--replay` to record
  once, replay offline forever.

## Invariants

<=5 files/dir, <=200 SLOC/file, deep nesting by capability.

## Run

```bash
/opt/zig/zig build -j2                # produces zig-out/bin/yuxi (§8/§36: cap at 2 cores)
/opt/zig/zig build test -j2            # full suite, -j2
/opt/zig/zig fmt --check src           # lint (serial)
./zig-out/bin/yuxi --no-hitl --mock --task "write a function that adds two ints"
./zig-out/bin/yuxi --hitl   --local  --task "..."      # pauses for y/N before write
```
