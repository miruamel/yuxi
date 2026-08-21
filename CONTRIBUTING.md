# Contributing

This repository is operated by a fully autonomous, non-HITL engineering agent.
Read [`AUTONOMOUS_AGENT.md`](AUTONOMOUS_AGENT.md) first — it is the one-page
governance summary: how the agent decides, the three escalation tiers, the
mandatory transparency rules, and how to override or question a decision.

## How to contribute

1. **Open an issue** for anything substantial. The agent publicly claims it
   within one hour of starting work (§26).
2. **Review the PR** when it lands. Every PR carries a mandatory public
   context comment with the decision rationale, alternatives considered,
   verification evidence, and rollback plan (§25/§41-B).
3. **Raise concerns on the PR thread.** The agent responds there; escalation
   to a human co-owner is a Tier-2/3 `question` issue, never a silent bypass.

## Branching & commits

- Branches: `<type>/<short-description>` (`feat`, `fix`, `refactor`, `perf`,
  `docs`, `test`, `security`, `release`).
- Commits: Conventional Commits — imperative subject scoped to one coherent
  change, body explains *why*.
- Merge: `gh pr merge <n> --squash --delete-branch` from a green CI head.

## Verification gates

Before a PR is mergeable:

- `/opt/zig/zig build -j2` → exit 0 (§8/§36: cap at 2 cores)
- `/opt/zig/zig build test -j2` → exit 0, concurrency capped at 2 cores
  (`taskset -c 0,1 /opt/zig/zig build test -j2` locally; CI runs
  `zig build test -j2`)
- `/opt/zig/zig fmt --check src` → exit 0 (serial)

All parallelizable steps run with `--jobs 2` / `-j2` (or the tool-specific
equivalent) per the non-negotiable resource invariant. Raising that limit
requires explicit architectural review and documented justification.

## Reporting issues

Use the issue templates. Label taxonomy:

- **Type:** `bug`, `feature`, `refactor`, `security`, `docs`, `test`
- **Priority:** `critical`, `high`, `medium`, `low`
- **Status:** `todo`, `in-progress`, `blocked`, `done`
- **Component:** `backend`, `infra`, `docs`

Open co-owner forks are tracked as `question` issues and are **not** built
silently — the agent defers and states the deferral in the PR context comment.