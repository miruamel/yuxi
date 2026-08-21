# Yuxi (玉溪) — Autonomous Software Evolution Engine (Zig 0.16)

Developed sketch of the 9-layer agentic loop. Selectable HITL / non-HITL.
The "brain" is an external LLM reached over HTTP (OpenAI-compatible) or a
local server (ollama/llama.cpp); `mock` runs fully offline for dev/test.

## Topology (loop)

```
Gateway -> Orchestrator -> (Builder -> Critic)* -> Compose -> Evaluator -> Deploy
                                          ^                          |
                                          \_______ Resilience <- Knowledge <- Monitoring
```

`Monitoring -> Gateway` is the outer autonomous cycle. One task runs a forward
pass. A rejected `Critic` regenerates that step with the critic's reason as
builder feedback; the `Evaluator` compiles and runs the composed program, and on
failure the pipeline rebuilds (up to 3 attempts) with the error fed back to the
builder (self-correction).

## Layers

1. **Gateway** — auth (optional `AE_TOKEN`), rate-limit counter, validation,
   PII sanitizer (naive `@` redaction), intent router.
2. **Orchestrator** — LLM task decomposer -> numbered `STEP:` plan.
3. **Builder** — LLM planner + generator -> writes a `.zig` file. HITL gate
   before write when `mode == hitl`.
4. **Critic** — fast-path denylist (`panic(`, `std.process.Child`, `@cImport(`) + LLM `APPROVE`/`REJECT` with reason; a `REJECT` regenerates the step.
5. **Evaluator** — compile + run the composed `gen_final.zig`; on failure, store the error and let the engine self-correct.
6. **Deploy** — commit the verified `gen_final.zig` to an isolated git repo in `workdir`; intermediate `gen_*.zig` are removed.
7. **Resilience** — per-run failure counter + circuit breaker; on LLM transport error, fallback to `mock`.
8. **Knowledge** — append structured events to the engine context log.
9. **Monitoring** — emit token + event metrics.

## LLM Transport

`llm/transport.zig` dispatches on `Ctx.backend`:
- `mock` — deterministic canned text per role (no network).
- `openai` — `OPENAI_BASE`/`OPENAI_API_KEY` (default `api.openai.com/v1`).
- `local` — `LOCAL_BASE` (default `http://localhost:11434/v1`).

All HTTP backends use `curl` via `std.process.run`.

## Invariants (applied from Locust)

<=5 files/dir, <=200 SLOC/file, deep nesting by capability.

## Run

```bash
/opt/zig/zig build -j2                # produces zig-out/bin/yuxi (§8/§36: cap at 2 cores)
./zig-out/bin/yuxi --no-hitl --mock --task "write a function that adds two ints"
./zig-out/bin/yuxi --hitl   --local  --task "..."      # pauses for y/N before write
```
