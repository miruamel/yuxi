# AUTONOMOUS_AGENT.md — Yuxi Engine Governance

One-page summary of how the autonomous agent operates on this repository, so
that contributors are never surprised by bot-driven PRs and understand the
accountability model. Last updated: 2026-08-21.

## Who is running this

This repository is operated by a fully autonomous, non-HITL software
engineering agent implementing the 41-section charter. It owns the complete
lifecycle: discovery, implementation, verification, release, and maintenance.
Human escalation exists only for existential architectural decisions and
regulatory/compliance matters.

## Escalation Tiers

| Tier | Scope | Examples | Action |
|---|---|---|---|
| 1 — Self-decide | Implementation details, refactors, tests, dependency updates | bug fixes, test additions, doc corrections | Implement, verify, ship via PR |
| 2 — Consult co-owner | Architectural pivots, breaking API, product-shaping, security architecture | `--dry-run`/`--hitl` gating (#2), runtime sandbox design (#41) | Open a co-owner decision issue, do NOT build until answered |
| 3 — Human escalation | Regulatory, legal, P0 security, critical production outage | CVEs with legal exposure, data breaches | Stop work, page a human, document before any action |

Open Tier-2/3 items are tracked as `question` issues and are **not** built
silently: the agent defers and states the deferral in the PR context comment.

## How decisions are made

Every substantial decision must be traceable, justifiable, and reversible:

1. **Traceable** — recorded in commit messages, issues, or PRs.
2. **Justifiable** — supported by empirical evidence (tests, graph analysis,
   metrics), not intuition. When Opportunity A is chosen over a similarly
   plausible Opportunity B, the trade-off is documented publicly (issue
   comment or AGENTS.md "Recent Decisions").
3. **Reversible** — a rollback strategy is defined before implementation.

Opportunities are scored `(Impact × Confidence) / (Cost × Risk)` across 18
categories. Critical correctness/security issues outrank features.

## Mandatory transparency

These are not optional; they are the primary accountability surface.

- **Public claiming (§26):** before starting substantial work, the agent posts
  a claim comment on the issue (approach, blast radius, risk mitigation, ETA,
  resource constraint).
- **Public context on every PR (§25):** immediately after `gh pr create`, the
  agent posts a comment explaining what was addressed, what alternatives were
  considered, the evidence that tipped the decision, verification logs, and
  the rollback plan.
- **Progress updates (§26):** if an issue takes longer than one calendar day,
  the agent posts a weekly progress update on the thread.
- **Split changelog (§28):** every release's CHANGELOG has a dedicated
  "Autonomous Agent Contributions" subsection listing each agent-driven PR
  with its impact, separate from human contributions.
- **Public post-mortem (§31):** any failure causing a rollback, a production
  incident, or a CI/CD outage lasting >1 hour becomes a public issue or
  Security Advisory, linked from the relevant PR and the subsequent release
  notes.

## Resource constraint (non-negotiable)

Every build, test, lint, and static analysis command — locally and in CI —
**must** cap parallelism at 2 cores:

```
zig build -j2
zig build test -j2
zig fmt --check src  # serial
```

This is enforced to prevent resource exhaustion and OOM on memory-tight
hosts (~354 MB free) and to keep CI reproducible. Raising the limit requires
explicit architectural review and documented justification.

## Repository invariants (enforced)

- ≤5 files per directory, ≤200 SLOC per file, deep nesting by capability.
- Dependency graph is a DAG — no cycles.
- `zig build`, `zig build test` (all pass), `zig fmt --check src` clean,
  no CRITICAL/HIGH security findings.

## How to override or question a decision

- **Question a PR:** comment on the PR thread. The agent responds with
  evidence; a SUGGESTION is a judgment call, a CRITICAL/WARNING must be
  addressed (or documented) before merge.
- **Request escalation:** comment on the relevant issue asking for Tier-2 or
  Tier-3 review. The agent will pause work and surface the decision to a
  human.
- **Emergency stop:** any contributor can ask the agent to halt; the agent
  stops and documents what was in flight.

## Where to find the audit trail

- **Decisions & rationale:** PR bodies, issue comments, AGENTS.md "Recent
  cycles" / "Recent Decisions".
- **Release provenance:** CHANGELOG.md "Autonomous Agent Contributions".
- **Operational rules:** this file; AGENTS.md bootstrap.
- **Issue tracker:** `gh issue list --state open` — Tier-2/3 forks are the
  `question`-labelled items.