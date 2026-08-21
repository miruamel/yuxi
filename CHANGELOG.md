# Changelog

## Unreleased
Fixes for the knowledge-base learning loop, which was broken on the primary
`--task` path and blind to the wall-clock cap. Both regressions were latent:
the `--kb` feature shipped in v0.1.0 and the `--max-time` cap in v0.5.0, but
neither reached the ledger the way the two earlier autonomy caps did.

### 🤖 Autonomous Agent Contributions
### `--max-time` cap now checked inside the attempt loop (fix, autonomy safety, §11/§14)
- `--max-time N` was documented as capping wall-clock per run, but `engine.run`
  only checked the cap once *before* the self-correction attempt loop — a single
  slow `evaluator.run` could blow past the bound undetected. The check now runs
  at the top of every attempt through a shared `wallClockExceeded(ctx, start_ns)`
  helper, so the cap bounds the whole loop, not just the pre-codegen gap.
- The helper prefers an injected `ctx.clock_ns` over the live
  `std.os.linux.clock_gettime`, mirroring the `llm_fn` seam, so the in-loop
  path is deterministically testable instead of requiring a sleep.
- New regression test in `plan_gate_test.zig`: a fast fake clock (0, 0, then
  `ns_per_s`) trips the per-attempt guard on the third tick while the pre-loop
  guard passes — proving the cap aborts before any `buildstep` or `evaluator.run`.
  All 4 `plan_gate` tests pass; full suite green (`zig build test -j2`, 11 roots).
- Files: `src/core/types.zig` (`Ctx.clock_ns` + `ClockNs`), `src/core/engine.zig`
  (per-attempt guard), `src/core/selfcorr/plan_gate_test.zig` (regression test).
### `clockNs` / `wallClockExceeded` moved to `runlife.zig` (refactor, §8 SLOC cap)
- The in-loop cap fix pushed `engine.zig` to 209 SLOC, breaching the §8 ≤200
  ceiling. The two clock helpers already belonged to `runlife.zig`'s domain
  (it owns the LAYER 7-9 tail and `flushRecord`); extracting them dropped
  `engine.zig` to 189 SLOC with no behavior change — every call site prefixed
  `runlife.`, and the in-loop regression test still passes. Same lesson as the
  earlier `finishRun`/`flushRecord` extraction: re-check the §8 SLOC ceiling
  after a feature lands, before it drifts over.
### `--kb` was a silent no-op on a single `--task` run (fix, reliability, §11/§12)
- `engine.newCtx` threaded `kb_max_lines`, `replay_path`, and `record_path`
  through to the `Ctx`, but **not `kb_path`** — so `ctx.kb_path` stayed `null`
  and every site guarded by it (`recordLesson`, `recordHealth`, `injectPrompt`)
  was a no-op. The headline KB feature was dead on the primary CLI path: only
  `--tasks` ever wrote a ledger, because `loop.runTasks` calls `recordBatch`
  directly with `cfg.kb_path` instead of going through the `Ctx`. The
  recently-added `--kb-stats` inspector (#40) read a ledger that single-run
  users could never populate.
- `newCtx` now sets `ctx.kb_path = cfg.kb_path`, so a single `--task` run
  persists its lesson, receives prior lessons in its decomposition prompt, and
  lets `--kb-stats` summarize a real ledger. No flag or schema change; the
  `--tasks` path is unaffected (it still calls `recordBatch` directly).


### `recordLesson` now persists the `--max-time` cap hit (fix, learn-loop, §12)
- `run_time_exceeded` was surfaced everywhere except the KB: `assessHealth`,
  `monitoring.report`, and `TaskResult` all emitted the `wall-time exceeded;`
  verdict clause and counter, but `recordLesson` never wrote `run_time_ex` —
  so a wall-clock-cap abort was visible in health and invisible in the
  ledger, and the next cycle's `injectPrompt` never steered away from it.
- Mirrors the `max_steps_ex`/`token_budgets_exceeded` persistence fixes
  (#27/#28): both `recordLesson` lesson formats now append
  `run_time_ex={d}`. `knowledge.recorders_test` asserts it.


### Stale doc pointer corrected (fix, repo-hygiene, §24)
- `AGENTS.md` named `ledger_test` as a live test file; that module was
  superseded by `recorders_test.zig` in `16daa1f`. Now points at the file
  that actually exists.


### `--max-time` / `--max-attempts` documented in `AGENTS.md` (fix, docs, §24)
- `printHelp` carried `--max-time` and `--max-attempts` (parseable, tested,
  wired through `Ctx`), but the authoritative flag list in `AGENTS.md` only
  listed `--max-tokens`/`--max-steps`. A user reading the docs could not
  discover the two autonomy caps that actually exist. Added both bullets
  (`--max-time` wall-clock cap, `--max-attempts` retry cap) in the
  `--max-tokens`/`--max-steps` block, keeping the list in sync with
  `core/config/config.zig: printHelp`.

### Governance hygiene: PR template, doc pointer, README glyph, dead import (fix, repo-hygiene, §24/§8/§41-E)
- `AGENTS.md` gained an `## Autonomous agent governance` section pointing at
  `AUTONOMOUS_AGENT.md` (the README already linked it, but the agent-facing
  entry point had no pointer). Open co-owner forks #2 and #41 are named as
  not-built-silently.
- `README.md` Repository invariants line still carried a literal `≤` — the
  prior cycle's summary claimed it was replaced with `<=`, but the edit never
  landed on disk. Now shell-safe.
- `src/core/selfcorr/plan_gate_test.zig` imported `config` and never used it;
  removed (Kilo Code Review nitpick). Build still green.
- **PR template added** (fix, repo-hygiene, §24/§41-E): `.github/PULL_REQUEST_TEMPLATE.md`
  now embeds the mandatory autonomous-agent context, blast radius, and rollback
  fields, and links `AUTONOMOUS_AGENT.md` prominently per §41-E. The README already
  linked the governance doc; the template was the missing touchpoint, so every
  future PR surfaces the accountability model by default instead of relying on
  the author to remember it.
- `CONTRIBUTING.md` added (fix, repo-hygiene, §24): the README linked
  `AUTONOMOUS_AGENT.md` and the PR template embedded the agent context, but
  there was no contributor-facing guide explaining how to open an issue,
  review a PR, or raise concerns. `CONTRIBUTING.md` now points at the
  governance doc and documents the branching/commit/verification-gate
  conventions, including the `--jobs 2` resource cap.


### Docs command sweep: every build/test/lint command capped at `-j2` (fix, repo-hygiene, §8/§36)

- Zig uses `-j2` (not `--jobs 2`); `--jobs 2` is a GNU make convention and
  was already wrong in `AUTONOMOUS_AGENT.md`. Sweep of every markdown command
  block found bare `zig build` / `zig build test` contradicting the constraint
  already named in `README.md:110` and `CONTRIBUTING.md:35`:
- `README.md` Build & Run, `DESIGN.md` Run, `AGENTS.md` Build & Run + Verify,
  `CONTRIBUTING.md` verification gates, `.github/PULL_REQUEST_TEMPLATE.md`
  verification checkboxes, and `AUTONOMOUS_AGENT.md` repository invariants
  all now carry `-j2` with an explicit §8/§36 comment.
- CI (`ci.yml`) already used `-j2`; the fix is purely documentation, no
  behavior change. `zig build -j2` and `zig build test -j2` both exit 0.

### `--kb-stats` CLI path now covered end-to-end (test, §11/§21)
- `knowledge.printStats` (main.zig:30-33) had no test at all — only its pure core
  `knowledge.summarize` was covered, and its `logLine` formatting plus the
  no-ledger short-circuit were unexercised. New CLI-shell test asserts both
  paths: no `--kb` short-circuits with "nothing to summarize" and exit 0; a
  populated ledger prints all six category counts, the latest line, and echoes
  the `--kb-max-lines` cap it applied (knowledge.zig:192). The unreadable-ledger
  path stays untested: `store.load` returns null for a missing file, so the
  "ledger empty" branch is unreachable in the test sandbox — documented, not
  chased. All 5 `main_test` roots pass.
### `assessHealth` `max_steps_exceeded` clause covered (test, §11/§30)
- The `--max-steps` abort verdict clause (monitoring.zig:174-178) had the same
  gap as the `run_time_exceeded` clause closed earlier: the unhealthy-cycle
  test sets critic_rejections/mock_fallbacks/retries/token_budgets but never
  `max_steps_exceeded`, so the branch was dead in tests. New test sets
  `ctx.deploys=1` + `ctx.max_steps_exceeded=1` and asserts the verdict carries
  "max-steps exceeded" and NOT "no deploy", proving the plan-cap abort is a
  distinct health signal (not folded into the generic no-deploy WARN). All 7
  `monitoring_test` roots pass.
### `--kb-stats` short-circuit dropped the `--kb-max-lines` cap (fix, reliability, §11/§12)
- `config.parse` short-circuited on `--kb-stats` and returned a struct with
  `kb_max_lines = null` (config.zig:130-131), so `knowledge.printStats` never
  reached its cap-echo line (knowledge.zig:192) — an operator who passed
  `--kb-max-lines` to the inspector saw the same output as one who didn't.
  The short-circuit now returns the parsed cap (bare form still defaults to
  200, matching `--cache`/`--report`/`--record`). New `--kb-max-lines=5`
  assertion in `main_test` covers the populated-ledger cap echo.
### `emitReportAndExit` temp-report path covered (test, §11/§21)
- `main.emitReportAndExit` writes a temp report and passes it to the health hook
  when the caller sets `--health-hook` WITHOUT `--report`. The existing hook test
  always supplied a `--report` path, so that branch was dead in tests — a
  regression there would have meant a hook firing with no machine-readable
  input. New test passes `report_path=null` + an unhealthy `TaskResult` and
  asserts the hook fires (sentinel written) and the temp report is cleaned up
  afterwards. All 4 `main_test` roots pass.
### `--kb-stats` echoes the `--kb-max-lines` cap (test, §11/§21)
- `knowledge.printStats` logs the bound it applied (knowledge.zig:192) so an
  operator can see it, but no test round-tripped it through the CLI. New
  assertion runs `--kb-stats --kb-max-lines=5` against the populated ledger
  and expects the `cap (--kb-max-lines): 5` line in stdout, exit 0.
### Human / Other Contributions
- (none this cycle)

## v0.6.0 (2026-08-21)
Seventh tagged release. Batches three substantive changes merged to `master` since v0.5.1.
### 🤖 Autonomous Agent Contributions
- **PR #38:** KB ledger now deduplicates identical lessons via `store.appendUnique` for the
  four recorders; recurring failures/critics/health lines recorded once, distinct lessons
  preserved under `--kb-max-lines` (fix, reliability/perf, §8).
- **PR #40:** `--kb-stats` read-only knowledge-ledger inspector added (feat, observability, §12/§30).
- **PR #42:** `deploy.run` now reports a real checkpoint status (`!bool`) and `engine.run` only
  counts `ctx.deploys` on a real commit; git spawned through a real-allocator `Threaded` io with
  the OS environ (fix, deploy honesty, §30).
### Human / Other Contributions
- **Co-owner:** README flag list + Safety section updated (`--kb-stats`, `--max-time`,
  `--max-attempts`); runtime sandboxing flagged as a deliberate design bet for co-owner input
  (issue #41).
- `feat(observability)`: `--kb-stats` is a read-only inspector that loads the configured `--kb`
  ledger, prints a category breakdown (total / deployed / failed / critic-rejected / health /
  batch / other + latest line), and exits 0 without running the engine. With no `--kb` path or an
  empty/absent ledger it prints a clear "nothing to summarize" line and still exits cleanly. The
  categorization core (`knowledge.summarize`) is a pure function with direct unit tests. #40.
- **Docs (§24):** README flag list + Safety section updated — `--kb-stats`, `--max-time`,
  `--max-attempts` now documented, and the Safety section states the containment-boundary gap
  (the critic denylist is a text fast-path, not a privilege boundary). Runtime sandboxing is a
  deliberate design bet flagged for co-owner input: issue #41.
Tagged from master `087921a` (CI green).

## v0.5.1 (2026-08-21)
Sixth tagged release. Security patch on top of v0.5.0.
- `fix(security)`: the critic's static safety denylist now matches dangerous constructs as **substrings** (`std.process`, `@cImport`, `@import("c")`, `asm`, `@export`) instead of exact tokens. An exact-token match was a real sandbox-escape bypass — indirection like `@field(std.process, "Child")` or `std.process.spawn` contains `std.process` but not the literal `std.process.Child`, so it passed the gate and reached the evaluator/deploy (CWE-265, #37). The mock backend's benign output never contains these substrings, so the green deploy path is unaffected. Behavior-preserving for legitimate code. Tagged from master `caa8c7f` (CI green).

## v0.5.0 (2026-08-21)
Fifth tagged release. Batching 7 merged PRs (#29, #30, #31, #32, #33, #34, #35) since v0.4.0 —
a security fix closing the gateway auth no-op (CWE-306, #35), the `--max-time` autonomy-safety
cap (#30), the `--max-attempts` retry cap (#31), bounded KB ledger on write (#29), the
`--report` tokens/max_steps_exceeded observability (#33), the `--expect` end-to-end CLI test
(#34), and the `--tasks` batch KB bound fix (#32). Tagged from master `e48c290` (CI green).
### Gateway enforces a real auth secret via `AE_TOKEN_EXPECTED` (fix, security, CWE-306/CWE-287, §11/§14)
- The gateway's auth was a *presence* check: any non-empty `AE_TOKEN` was
  accepted, which authenticates nothing (CWE-306 Missing Authentication /
  CWE-287 Improper Authentication). Now, when the operator sets
  `AE_TOKEN_EXPECTED=<secret>`, the presented `AE_TOKEN` must match it via a
  constant-time compare or the run is rejected (fail-closed). Without
  `AE_TOKEN_EXPECTED` the legacy behavior is preserved (any non-empty token or
  none accepted), so dev/offline runs and every existing test are unchanged.
  This only corrects the check the engine already claimed to perform — it does
  NOT gate deploys (issue #2's deploy-gating fork stays reserved for the
  co-owner). `gateway_test.zig` adds three cases: mismatch → reject, missing
  token → reject, correct token → admit (and PII still sanitized post-auth).


### Wall-clock autonomy cap: `--max-time N` (feat, autonomy safety, §11/§14)
- New `--max-time N` caps how long a single engine.run may take (seconds),
  aborting fail-closed once the wall-clock budget is spent. An unattended
  autonomous run with a hung build/eval/deploy would otherwise stall forever;
  this bounds the whole run the way `--max-steps` bounds decomposition and
  `--max-tokens` bounds LLM spend. Off by default (`max_time_ms == null`):
  existing pipelines and every current test are unchanged. Plumbing mirrors
  the other caps: `config.parse` → `Config.max_time_ms` (seconds→ms) →
  `Ctx.max_time_ms` (via `engine.newCtx`) → a monotonic-clock check at the
  top of the self-correction loop in `engine.run`. On expiry it increments
  `ctx.run_time_exceeded` and returns `finishRun` (no deploy). Mirrors
  `max_steps_exceeded`/`token_budgets_exceeded`: `monitoring.assessHealth`
  emits a dedicated `wall-time exceeded; ` WARN so the cap hit is machine-
  distinguishable from a generic failure, and the JSON report carries the
  counter. Tests: `config_test` asserts `--max-time 2` → 2000 ms; a new
  `engine.run` test asserts a zero cap aborts before deploy with
  `run_time_exceeded == 1` and the verdict persisted to the KB. This is an
  autonomy-safety bound only; it does not touch the reserved issue #2
  deploy-gating fork.

### Run-lifecycle tail extracted to `core/runlife.zig` (refactor, §8 SLOC cap)
- The `--max-time` feature pushed `engine.zig` to 229 SLOC, a §8 >200 breach.
  `finishRun` + `flushRecord` (the LAYER 7-9 resilience/knowledge/monitoring
  tail and record flush) moved into a new `core/runlife.zig` module, dropping
  `engine.zig` to ~180 SLOC and keeping `core/` at 5 top-level files (§8 OK).
  `engine.run` now calls `runlife.finishRun` / `runlife.flushRecord`;
  `build.zig` registers the module in the all-to-all DAG. No behavior change.

### Self-correction retry cap: `--max-attempts N` (feat, autonomy tuning, §11/§14)
- The build/eval self-correction loop was hardcoded to 3 attempts in
  `engine.zig`; `--max-attempts N` now makes that budget operator-configurable
  — the fourth member of the autonomy-cap family alongside `--max-steps`,
  `--max-tokens`, and `--max-time`. An unattended loop can now deliberately
  widen retries (e.g. flaky eval) or narrow them (fail fast). `Ctx.max_attempts`
  (`?usize`, null → historical default 3) flows `config.parse` (`--max-attempts`)
  → `engine.newCtx` → the attempt loop bound (`ctx.max_attempts orelse 3`).
  Unlike the other three caps this is NOT a fail-closed safety abort: exhausting
  retries is the normal "nothing deployed" outcome, so it reuses the existing
  health-verdict path rather than minting a new `attempts_exceeded` clause.
  Help text + `--help` updated. Tests: `config_test` asserts `--max-attempts 5`
  → 5 (and null by default); a new `engine.run` test asserts `max_attempts=1`
  stops after one attempt with no deploy. Off by default (preserves 3).
### Batch KB ledger honors `--kb-max-lines` (fix, reliability, PR #32)
- `--tasks` mode persisted its aggregate health summary via `knowledge.recordBatch`, which called `store.save(.., null)` and ignored the operator's `--kb-max-lines` cap — reopening the unbounded-growth hole #29 closed for the per-run paths. `recordBatch` now threads `kb_max_lines` (wired from `loop.runTasks` → `cfg.kb_max_lines`), so a continuous `--tasks` engine set to a cap stays bounded on the batch path too. Added a regression test asserting the bound holds on write. Behavior unchanged when no cap is set.

### Run health report exposes `tokens` + `max_steps_exceeded` (feat, observability, §11/§14)
- `monitoring.TaskResult` / the `--report` JSON now carry `tokens` (real LLM
  spend this run) and `max_steps_exceeded` (plan-cap aborts) alongside the
  existing counters, so an external CI gate can read cost and plan-cap signals
  without parsing logs. The report had dropped both since it was added, leaving
  a gate blind to cost and `--max-steps` violations. `monitoring.taskResult`
  populates the new fields from `Ctx`; `writeReport`/`appendResult` serialize
  them; `monitoring_test` asserts both appear. Behavior-preserving — no engine
  logic or verdict change; off by default.
### KB ledger now bounded on write (fix, reliability/perf, §8, PR #29)
- `knowledge.save` appended lessons without limit while only `tailLessons`
  bounded what got injected into the next decomposition prompt. For a
  continuously running autonomous engine that meant unbounded disk growth and
  an O(n) reload of the whole ledger every run. `save` now enforces
  `--kb-max-lines` on write: after appending, if the file exceeds the bound it
  is rewritten to its last N lines. Off by default (null) preserves the prior
  unbounded behavior. Storage primitives (`load`/`save`/`tailLessons`) were
  extracted into `knowledge/store.zig`, dropping `knowledge.zig` from 203 →
  122 SLOC (was a §8 >200 breach) and keeping `knowledge/` at 4 files (≤5 §8).
  `knowledge.zig` re-exports `load`/`save` so callers/tests are unchanged.
  Added regression tests for bounded + unbounded save.

## v0.4.0 (2026-08-20)
Fourth tagged release. Batching 6 merged PRs (#20, #24, #25, #26, #27, #28) since v0.3.0 —
a security fix (CWE-214, #20), docs/help sync (#24), offline replay resilience (#25),
the `--max-steps` autonomy-safety cap (#26), the §30 observability correction (#27),
and its KB-ledger follow-on (#28) that close the `--max-steps` learn loop. No breaking
changes; the v0.3.0 flag surface and JSON report schema are forward compatible.
Tagged from master (CI green).

### Keep LLM API key out of the process table (fix, CWE-214, PR #20)
- `llm/http.zig` passed the `Authorization: Bearer <key>` header as a curl
  `-H` argv element, making the LLM secret world-readable via `ps` / process
  listing on any shared host or CI runner. It now writes the bearer header to a
  `0600` temp config file and hands it to curl via `-K`, so the key never
  enters argv. `fs.writeFileSecret` adds the `0600` open mode; the temp file is
  deleted after the request. Added a regression test asserting the header lands
  in the file (proving it left argv) and the file is cleaned up.

### Docs/help sync with shipped flag surface (fix, repo-hygiene, §24, PR #24)
- `config.printHelp` omitted `--tasks FILE` (batch plan mode) though `config.parse`
  already accepted it and README listed it; the help line is now present so
  `--help` is the authoritative flag list README claims. README's Flags +
  Environment block gained `--report`, `--health-hook`/`--always-hook`,
  `-V/--version`, and the CWE-214 note (bearer key via `curl -K`, never argv).
  `config_test` guards the `--tasks` parse contract. No engine behavior change.


### Offline replay degrades to mock on exhaustion (fix, reliability, §27/§29)
- `transport.complete` used to hard-fail the whole offline run
  (`error.ReplayExhausted`) the moment a run needed one more LLM call than the
  recorded transcript held — e.g. a retried attempt, a regenerated step, or a
  longer plan than was captured. That broke the engine's own offline/CI test
  path on any legitimate replay growth. Now, when the network backend is
  replaying, exhaustion falls back to the deterministic `mock` for the
  remaining calls (same resilience philosophy as the LLM circuit breaker) while
  still logging the gap, so a genuinely misconfigured (empty) replay stays
  visible. `ctx.mock_fallbacks` is incremented so the autonomy-health counters
  already track it. `transport_test` now asserts the fallback (no error,
  `mock_fallbacks` +1) past a short transcript.

### Plan-size bound: `--max-steps N` (feat, autonomy safety, §11/§14)
- New `--max-steps N` caps how many steps the orchestrator may autonomously
  decompose. If the LLM plan exceeds N, `orchestrator.run` aborts the run
  before any codegen/build/deploy (the decomposition analogue of `--max-tokens`,
  which bounds LLM spend). An unbounded decomposition is a real autonomy risk —
  runaway scope and unbounded LLM/hardware cost — so this lets an operator
  bound the engine's blast radius per task. Off by default (`max_steps == null`):
  existing pipelines and every current test are unchanged. Plumbing:
  `config.parse` → `Config.max_steps` → `Ctx.max_steps` (via `engine.newCtx`),
  checked in `orchestrator.run`. Help text, README, AGENTS.md, and a parse +
  end-to-end abort test cover it. This is an autonomy-safety bound only; it
  does not touch the reserved deploy-gating fork tracked in issue #2.

### `--max-steps` cap now a distinct health verdict (fix, §30, PR #27)
- The `--max-steps` abort (#26) was emitted as the generic `no deploy; `
  verdict, polluting the next cycle's `injectPrompt` with a false "plan
  failed to build" signal. Mirrors `token_budgets_exceeded`: `Ctx` gains
  `max_steps_exceeded`; `orchestrator.run` increments it on cap hit (and logs
  the reason); `monitoring.assessHealth` emits a dedicated
  `plan exceeded max-steps; ` WARN so the cap hit is machine-distinguishable
  from a generic failure. `orchestrator_test` asserts the counter == 1.

### Knowledge ledger now records `--max-steps` cap hits (fix, learn-loop, PR #28)
- `knowledge.recordLesson` — the core learn→inject ledger — omitted
  `max_steps_exceeded`, so a `--max-steps` abort was never persisted and future
  `injectPrompt` steering stayed blind to a blown cap. Mirrors
  `token_budgets_exceeded`: both `allocPrint` lesson formats now append
  `max_steps_ex={d}` and the doc-comment counter list includes cap hits.
  `ledger_test` asserts `max_steps_ex=1` appears in the loaded KB.

### Carried forward (open co-owner forks)
- #2 --dry-run/plan-mode and --hitl deploy gating — not addressed this release
  (deliberate: reserved fork, surfaced on #2 for co-owner decision).


## v0.3.0 (2026-08-20)

Third tagged release. Batching the 5 merged PRs (#18, #19, #21, #22, #23) since v0.2.0 —
machine-consumable health report + exit code (#18), verdict reason in the
report (#19), external health-hook
gating (#21), CLI parse-error exit-code contract (#22), and a build-time
version stamp + `--version` (#23). The observability batch makes the engine's
own autonomy-health observable to external gates, with `--version` and a
report `version` field so a gate can correlate verdicts with the exact
engine version. (The LLM key-out-of-argv CWE-214 fix is PR #20, which merged
after this tag and ships in v0.4.0.) Tagged from master 134f9b2 (CI green).


### Machine-consumable run health report (feat, §12/§30)
- `monitoring.writeReport` + `--report[=FILE]` emit a JSON run report (single
  `TaskResult`, or a `tasks` array + `batch_healthy` for `--tasks`). The report
  carries the autonomy-health verdict from `monitoring.assessHealth` (the single
  source of truth) so CI / cron / the co-owner's deploy-gating can read the
  engine's own health without parsing logs. Strings are JSON-escaped (RFC 8259
  control range) so semi-trusted task text can't break the document.
- `main` now exits non-zero when the run verdict is unhealthy (`std.process.exit(1)`),
  so a healthy mock run stays exit 0 and every existing test path is unaffected.
  The optional `--report` JSON exposes the same verdict to machine consumers
  independent of the process status.
- `monitoring.TaskResult` is now the single shared result shape (was duplicated
  in `loop.zig`); `loop.runTasks` and `main` both consume it.
- Invariant fix (§8): split the 202-SLOC `knowledge/knowledge_test.zig` into
  `knowledge/store_test.zig` (save/load/injectPrompt) and
  `knowledge/ledger_test.zig` (recordLesson/Health/Critic/Batch); `knowledge/`
  stays at 3 files.
- Restored two flags dropped during a prior corruption-recovery:
  bare `--record` (default `.yuxi_record.txt`) and `--kb-max-lines=N`

### Run report now carries the verdict reason (feat, §12 follow-on)
- `monitoring.TaskResult` gained a `verdict: []const u8` field (the
  machine-readable *why* a run is unhealthy, owned dup of
  `assessHealth`'s verdict). `writeReport` now emits `"verdict":"…"` per task,
  so a CI / co-owner gate reading `"healthy":false` can branch on the reason
  instead of only the boolean. `monitoring.taskResult(alloc, task, ctx, hv)`
  centralizes the borrow→own dup; `main`/`loop` free their copies explicitly.
- New unit test covers the report shape for both single and batch, including a
  verdict containing a JSON-breaking quote (escaped correctly → valid JSON).
- Also fixed a latent per-element leak in the `--tasks` path: `main` now frees


### External health gating via `--health-hook` (feat, §12 follow-on, PR #21)
- New `--health-hook <CMD>`: after the run, `<CMD> <report>` is spawned when the
  verdict is unhealthy (or always with `--always-hook`). It consumes the
  machine-readable `--report` JSON so a CI job or co-owner deploy policy can act
  on the verdict without the engine implementing the gate itself — the issue #2
  deploy-gating fork is intentionally NOT built here. If a hook is set but no
  `--report` was requested, a temp `0600`-free report is written so the hook
  still receives input. The hook is spawned through a real-allocator `Threaded`
  io (the global single-threaded io has a failing allocator and OOMs on spawn,
  same trap as `evaluator.runTo`); a hook failure is logged, never fatal. Added
  `main_test` proving the hook fires on unhealthy, is skipped on healthy

### CLI parse errors now exit non-zero (fix, §30 contract, PR #22)
- `main` previously did `config.parse(...) catch return;` — in a `!void` main
  that yields success, so **any** malformed invocation (e.g. missing `--task`)
  exited 0, which contradicted the exit-code contract CI/cron gate on (#18/#19/
  #21). Now `--help` still exits 0 (a successful info request), but a genuine
  parse error (`MissingTask`) exits 1. `main_test` shells the built binary and

### Build-time version stamp + `--version` (feat, §12/§28 follow-on, PR #23)
- The engine now carries its own version. `build.zig` detects it via
  `git describe --tags --always --dirty` at build time and injects it into every
  module through a `build_options.version` value (no `version` constant in
  `src/`, keeping the tag-based versioning convention). `git` failures (e.g. a
  hermetic tarball build) degrade to `""` rather than breaking the build.
- New `--version`/`-V` flag prints `yuxi <version>` and exits 0, on the same
  success contract as `--help`. `config` returns `error.VersionRequested`,
  `main` treats it like `HelpRequested` (exit 0).
- `monitoring.writeReport` now emits a top-level `"version"` envelope field on
  every report (single and batch), so an external gate comparing reports across
  deploys can tell which engine version produced each — a release stamp that
  travels with the artifact. `main` passes the build-time version into the
  report writer.
- Tests: `config_test` proves `--version`/`-V` are reachable
  (`VersionRequested`); `monitoring_test` asserts the `version` envelope field
  for both single and batch; `main_test` shells the built binary and checks
  `yuxi --version` prints the `yuxi v…` stamp and exits 0.
- CI: `actions/checkout` now uses `fetch-depth: 0` + `fetch-tags: true` so the
  version stamp resolves a real tag under GitHub Actions (default shallow
  clones yielded an empty stamp).




## v0.2.0 (2026-08-20)

Second tagged release. Batching the 8 merged PRs (#8–#16) since v0.1.0 —
plan-quality gating, hardened + observable network LLM path, safer knowledge
injection, honest health verdicts, a security fix, and a CLI-help/docs
correction. No breaking changes; the v0.1.0 pipeline + flags remain forward
compatible. Tagged from master 35e48e3 (CI green).

### Highlights
- Plan critic gate (PR #8). engine.run reviews the orchestrator's decomposition
  before codegen; a REJECT aborts with a recorded lesson instead of shipping
  weak code. Always-on, fail-fast, non-breaking.
- Hardened network LLM path (PR #13 + #14). transport.complete delegates to
  llm/http.zig, which retries curl up to 3x (bounded, no sleep) with
  -m 60 --connect-timeout 10, so a transient failure no longer silently
  degrades to the mock backend. Recovered retries surface as Ctx.network_retries
  (observability only — does not trip the health verdict).
- Correct, safe JSON (PR #15). http.jsonEscape now escapes the full RFC 8259
  control range (U+0000-U+001F), closing a silent mock-fallback triggered by
  raw control bytes in semi-trusted input (KB lessons, evaluator errors).
- Bounded KB injection (PR #12). --kb-max-lines[=N] caps the lessons appended to
  each prompt (bare = 200, default off). Unbounded prompts no longer bloat on a
  long-lived KB.
- Honest health + closed learning loop. monitoring.assessHealth is the single
  source of truth for cycle health (PR #11); the --tasks batch summary and the
  KB can no longer disagree. Plan-reject no longer truncates the learning loop
  (PR #9), and builder-level mock fallbacks are now counted (PR #10).
- Security fix (PR #7). the PII redactor now removes the whole @-token
  (e.g. user@corp.com -> <redacted>), closing an email-domain leak.
- CLI help + docs correctness (PR #16). yuxi --help was stale — it omitted
  --cache, --replay, --record, --kb, --kb-max-lines, --expect, and --tasks.
  The help surface is now authoritative, with a test locking it against
  regression.

### Engineering
- CI green on push/PR: zig build, zig build test, zig fmt --check src.
- Config parsing moved into core/config/ (its own subtree) and gained
  config_test.zig; core/ stays within the five-file ceiling (Section 8).
- No binary artifacts are attached; this is a source tag, consistent with v0.1.0.

### Carried forward (open co-owner forks)
- #2 --dry-run/plan-mode and --hitl deploy gating — not addressed this release.

### Maintenance & Docs
- `docs`: `yuxi --help` was stale — it omitted `--cache`, `--replay`,
  `--record`, `--kb`, `--kb-max-lines`, `--expect`, and `--tasks`, all of which
  were already implemented and parsed. Rewrote `printHelp` (now in
  `core/config/config.zig`) to group flags by Mode / Backend / Task / Knowledge
  / LLM I/O / Batch and print the authoritative surface. `README.md` and
  `AGENTS.md` flag lists were updated to match and now point at `--help` as the
  source of truth. This is a genuine docs defect, not cosmetics: a co-owner or
  user running `--help` couldn't discover the real feature set.
- `refactor`: `config.zig` moved into `core/config/config.zig` (its own nested
  subtree) and gained `core/config/config_test.zig`, keeping `core/` at the
  five-file ceiling while adding parse coverage. The test asserts backend
  parsing, that off-by-default features stay off, `--kb-max-lines` defaults to
  200 (bare) and parses N, and that `--help`/`missing-task` raise their error
  paths (locking the help surface against future regressions). `build.zig`
  module root + test list updated; call sites unchanged (module-name import).
### Features
- `feat`: plan-quality critic gate. `engine.run` now reviews the orchestrator's
  decomposition *before* codegen (LAYER 2.5). `critic.reviewPlan` reuses the
  critic transport + verdict parser with a plan-specific prompt; on REJECT it
  increments `critic_rejections`, persists a `knowledge.recordCritic("plan", …)`
  lesson, logs `engine: ABORT at plan critic`, and returns before any codegen
  or deploy. Always-on, fail-fast, non-breaking — the default backend returns
  APPROVE. New `src/core/selfcorr/plan_gate_test.zig` exercises the reject
- `feat`: bounded HTTP retry for the network LLM backends (`.openai`/`.local`).
  `transport.complete` delegated the network path to a new `llm/http.zig`
  module whose `http.complete` retries the `curl` call up to 3 times (bounded
  attempts, no sleep) and passes `-m 60 --connect-timeout 10`, so a transient
  5xx / connection reset / timeout no longer aborts the whole build and
  triggers a silent `resilience.fallback` to the mock backend (degrading the
  run with no visible signal). A persistent failure still propagates
  `error.RequestFailed` for the existing fallback path to handle. The
  mock/replay/cache paths are untouched. `transport.zig` shrank to a dispatch
  stub; the JSON-escape and content-extraction unit tests moved into `http.zig`
  (registered in `build.zig`).
  - `feat`: network-retry observability. Following the bounded HTTP retry, a
  recovered transient network failure now increments a new `Ctx.network_retries`
  counter, surfaced in `monitoring.report` so the autonomy loop can read its own
  network-retry churn (e.g. a flaky endpoint retrying every cycle). It is
  deliberately *not* a degradation signal: `assessHealth` does not trip on it
  (unlike `mock_fallbacks`), because a run that recovers is healthy. No CLI
  surface or new module added.
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
- `fix`: `http.jsonEscape` now escapes the full RFC 8259 control range
  (U+0000–U+001F), not just `"`, `\`, `\n`, `\r`, `\t`. The prompt path
  carries semi-trusted input — KB lessons, recorded evaluator errors, and task
  text — which can contain raw control bytes (notably ESC `0x1B`, form-feed,
  vertical tab from terminal/compiler output). A raw control char previously
  leaked unescaped into the `-d` JSON body, producing malformed JSON; the
  endpoint rejected it (`-f` → empty body → `error.RequestFailed`), and the
  bounded retry in PR #13 then fell through to `resilience.fallback` — a silent
  mock degradation triggered by *input content*, not a real network fault.
  Control chars now encode as `\u00XX`. `extractContent` already decoded `\b`
  and `\f` on the way back, so this also makes the encode/decode pair
  consistent. New regression test asserts a raw ESC + vertical tab escapes to
  `\u001B`/`\u000B`. Also documented in AGENTS.md: `llm/http.zig` shells out to
  `curl` via **array argv** (no shell), so the header/url/body are not subject
  to shell injection.
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
  in `knowledge/ledger_test.zig`.
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
