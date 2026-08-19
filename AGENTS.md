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

## Deploy layer (verified checkpoint)
The composed `gen_final.zig` (one per task) is committed into an *isolated* git repo inside
`ctx.workdir` (default `ae_out/`) via `deploy.run`: `git -C <wd> init` + add
+ commit. Keeps engine-run artifacts out of the engine repo. Commits use an
explicit identity (`git -c user.name=Yuxi Engine -c user.email=yuxi@localhost`)
because the spawned `git` inherits no identity in this env.
**Gating:** `engine.zig` only calls `deploy.run` when `evaluator.run`
(`zig build-exe` compile + run) returns true. Invalid output is never committed and no
workdir repo is created.

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


## Invariants (from DESIGN.md)
<=5 files/dir, <=200 SLOC/file, deep nesting by capability.
Flat imports from `src/`: `@import("core/types.zig")`, not `../core/types.zig`.

## Known gaps (next cycles)
- Remote `miruamel/Xunma` is 404; no push/release until a remote is provisioned
  (CI workflow exists but cannot run without one).
- The engine now composes every step into ONE runnable program (`gen_final.zig`):
  each step emits a `pub fn stepN() void` fragment, the engine merges them under a
  `main` harness, and the evaluator compiles+runs the single artifact. Deploy gates
  on a clean compile+run; one artifact per task, not N disconnected files.
- Evaluator has a regression test (`src/evaluator/evaluator.zig`): a compiling
  program is accepted and a non-compiling one is rejected, via a real
  `zig build-exe` + run using the pre-initialized `std.Io.Threaded.global_single_threaded`
  host Io (avoids allocating an Io, which would panic under `zig build test`'s
  failing-allocator re-run). `src/tests.zig` is the test root, so `zig build test`
  covers cache, evaluator, and engine composition — not just the cache.
- Real LLM backends (`.openai`/`.local`) shell `curl` (`transport.httpComplete`); `curl`
  must be on PATH at runtime. `extractContent` unescapes JSON `\n`/`\t` so multi-line
  generated code survives the OpenAI response — a regression test now guards this.
- `.gitignore` covers binaries, build dirs, `gen_*.zig`, `.yuxi_cache`, `/ae_out/`.
