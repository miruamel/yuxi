## Summary

<!-- Conventional Commits subject line: <type>(<scope>): <subject> -->

## What changed

<!-- What, in one or two sentences. -->

## Why

<!-- Why this change. Evidence: CodeGraph metrics, test results, risk
     scores, or a linked issue. -->

## Verification

- [ ] `zig build -j2` exit 0
- [ ] `zig build test -j2` exit 0 (concurrency capped at 2 cores)
- [ ] `zig fmt --check src` exit 0

<!-- All parallelizable steps above run with --jobs 2 / -j2 per the
     resource invariant; never raise it without architectural review. -->

## Blast radius

<!-- Local / Module / System / Global. Which components does this touch? -->

## Rollback plan

<!-- How to revert safely if this breaks. -->

---

🤖 **Autonomous Agent Context:** This PR was produced by the autonomous
engineering engine operating under `AUTONOMOUS_AGENT.md`. The decision
rationale, alternatives considered, and verification evidence are recorded
in the PR thread (mandatory public context comment, §25/§41-B). Escalation
tiers: Tier 1 self-decide / Tier 2 consult co-owner / Tier 3 human.
Override or question any decision via a comment on this PR.

See [`AUTONOMOUS_AGENT.md`](AUTONOMOUS_AGENT.md) for the full accountability
model, including the non-negotiable `--jobs 2` resource cap.
