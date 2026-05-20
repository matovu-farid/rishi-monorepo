---
description: Build a feature using the six-role agent team — research, plan, architect, tdd code, review
argument-hint: <feature description in plain English>
---

The user wants to build the following feature:

$ARGUMENTS

Run the full agent-team lifecycle. Use TodoWrite to track each phase. At every phase boundary, briefly summarize the agent's findings for the user before moving on so they can redirect if needed.

## Phase 1 — Research (parallel where possible)

Dispatch `team-researcher` to:
- Verify any SDK / library assumptions implied by the feature description.
- Survey existing code that the feature will touch or extend (entry points, related modules, similar patterns already in the repo).
- Confirm constraints: relevant `CLAUDE.md` rules, project conventions, lockfile pins, related memory entries.

If the feature touches multiple independent areas, dispatch multiple researchers in parallel — one per area.

## Phase 2 — Plan

Dispatch `team-planner` with the researcher's evidence. Produce:
- 2–3 viable approaches with tradeoffs.
- Recommended approach with reasoning.
- Build sequence (ordered steps, file paths, no code).
- Test strategy.
- Production gotchas + go/no-go.

**Checkpoint**: relay the plan summary to the user. Ask for go-ahead unless the user said "autonomous" or "just do it".

## Phase 3 — Architect

Dispatch `team-architect` with the locked plan. Produce:
- Exact file paths to create/modify.
- Public interfaces / type signatures.
- Layer placement against existing ports/adapters.
- Failure modes per code path.

## Phase 4 — Test-first (TDD red phase)

Dispatch `team-tester` with the architecture. They write FAILING tests against the public interfaces. Confirm the tests fail by running the test command.

## Phase 5 — Implement (green phase)

Dispatch `team-coder` with the failing tests + architecture. They implement the minimum needed to turn green. Run typecheck and tests after.

## Phase 6 — Review

Dispatch `team-reviewer` on the resulting diff (`git diff main` or the relevant range). They report findings filtered by ≥80% confidence.

## Phase 7 — Synthesize + report

Summarize for the user:
- What got built.
- Files changed (one-line each).
- Reviewer findings — block-ship items vs polish.
- Test + typecheck status.
- Suggested commit message(s).

Do NOT commit unless the user explicitly asks.

## Notes for the orchestrator (you)

- Dispatch agents in **parallel** when work is independent (e.g. multiple researchers).
- Trust but verify: an agent's summary describes intent, not what landed on disk. Spot-check key files.
- If an agent's output conflicts with another, surface the conflict to the user — don't paper over.
- Don't let agents bikeshed across phases. The planner decides approach, the architect decides shape, the coder implements. Each phase locks the previous.
- If the user said "autonomous", skip the Phase 2 checkpoint and proceed.
