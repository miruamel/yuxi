# Yuxi (玉溪) — Autonomous Software Evolution Engine (Zig 0.16)

Developed sketch of the 9-layer agentic loop. Selectable HITL / non-HITL.
The "brain" is an external LLM reached over HTTP (OpenAI-compatible) or a
local server (ollama/llama.cpp); `mock` runs fully offline for dev/test.

## Topology (loop)

```
Gateway -> Orchestrator -> Builder -> Critic -> Evaluator
   ^                                        |
   |                                        v
Monitoring <- Knowledge <- Resilience <- Deploy
```

`Monitoring -> Gateway` is the outer autonomous cycle. One task runs a forward
pass; a rejected `Critic` triggers one retry via `Resilience` fallback before
`Evaluator` compile-checks each generated file.

## Layers

1. **Gateway** — auth (optional `AE_TOKEN`), rate-limit counter, validation,
   PII sanitizer (naive `@` redaction), intent router.
2. **Orchestrator** — LLM task decomposer -> numbered `STEP:` plan.
3. **Builder** — LLM planner + generator -> writes a `.zig` file. HITL gate
   before write when `mode == hitl`.
4. **Critic** — fast-path rules (rejects `panic(`) + LLM `APPROVE`/`REJECT`.
5. **Evaluator** — `zig ast-check` compile gate per file.
6. **Deploy** — `git add <path>` + `git commit` on stable (guarded).
7. **Resilience** — circuit breaker; on LLM failure, fallback to `mock`.
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
zig build-exe src/main.zig -femit-bin=yuxi
./yuxi --no-hitl --mock --task "write a function that adds two ints"
./yuxi --hitl   --local  --task "..."      # pauses for y/N before write
```
