# Yuxi (玉溪) — Autonomous Software Evolution Engine

Zig 0.16.0 project rooted at `src/` (root = `src/`). Implements the autonomous
evolution engine described in `DESIGN.md`.

## Build & Run
```bash
/opt/zig/zig build                 # produces zig-out/bin/yuxi
./zig-out/bin/yuxi --no-hitl --mock --task "write a function that adds two ints"
./zig-out/bin/yuxi --hitl --local --task "..."   # pauses y/N before write
```

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

## Invariants (from DESIGN.md)
<=5 files/dir, <=200 SLOC/file, deep nesting by capability.
Flat imports from `src/`: `@import("core/types.zig")`, not `../core/types.zig`.

## Known gaps (next cycles)
- CI workflow added (.github/workflows/ci.yml) but needs a remote to actually run.
- Git repo initialized (initial commit eacb0ca); `.gitignore` covers binaries
  (`yuxi`, `ae`), build dirs (`zig-out/`, `zig-cache/`), `gen_*.zig`, `.yuxi_cache`.
