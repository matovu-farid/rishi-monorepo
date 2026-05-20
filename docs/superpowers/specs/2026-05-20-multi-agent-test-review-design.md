# Multi-Agent Test Review & Bug Fix Workflow

**Date:** 2026-05-20
**Status:** Approved
**Scope:** `apps/rishi-electron` test suite (unit + e2e)

## Purpose

Audit the rishi-electron test suite for (a) parity gaps between format-specific tests (PDF / EPUB / MOBI / AZW3), (b) best-practice violations, and (c) production bugs surfaced by tests. Confirmed bugs are fixed via TDD by a coordinated agent team. Findings, dialog, and fix history are persisted to disk for resumability and auditability.

## Goals

- Surface every real bug the tests reveal — without false positives polluting the backlog.
- Bring format-pair tests to parity where parity makes sense.
- Raise the average test quality (real DB over mocks, behavior over implementation, etc.) without unrelated rewrites.
- Produce a complete paper trail of every claim, review, rebuttal, fix, and verification.

## Non-Goals

- No mobile or web reader work. Electron only (per repo convention).
- No general refactoring unrelated to a confirmed bug or parity gap.
- No new test infrastructure (frameworks, runners) — work within Vitest + Playwright as they exist.
- Triage is not test deletion. A bad test gets flagged in `practices-audit.md`, not deleted, unless explicitly approved.

## Run Phases

Two runs, in order:

1. **Pilot** — warm-restore slice (4 e2e specs + counterparts). Validates the workflow end-to-end before scaling.
2. **Full sweep** — every test file in `apps/rishi-electron`, batched by area. Includes a human gate after triage to scope which confirmed bugs get fixed this run.

## Agent Roles

Five distinct roles (Tester and Reviewer each appear at two stages). Each dispatch is a fresh subagent. No agent communicates with another directly; the orchestrator (main thread) routes work by reading file output and dispatching the next role.

| Role | Subagent type | Job |
|---|---|---|
| Planner | `team-planner` | Read assigned scope, produce `plan.md` (parity matrix, audit checklist, TDD architecture guidance). |
| Tester | `team-tester` | Read test files + plan. Identify parity gaps, practice violations, and suspected bugs. Write finding files. |
| Reviewer-1 | `team-reviewer` | Verify a finding catches a real production bug (not test flake, not testing-the-test). Append CONFIRM / REJECT. |
| Tester (rebuttal) | `team-tester` | If rejected, ACCEPT-REJECTION or REBUT. One rebuttal max. |
| Tiebreaker | `feature-dev:code-reviewer` | Final binding verdict if rebuttal disputes rejection. Distinct agent type from Reviewer-1 to avoid shared blind spots. |
| Coder | `team-coder` | For CONFIRMED findings: write red test if missing, implement minimal fix, commit. |
| Code-reviewer | `team-reviewer` | Review the coder's diff. Coder gets one rebuttal; deadlock → tiebreaker. |

## File Layout

All artifacts live under `.agent-review/` at the repo root, gitignored from the start.

```
.agent-review/
  pilot/
    plan.md
    findings/
      001-pdf-warm-restore-stale-page.md
      002-epub-warm-restore-race.md
      ...
    parity-gaps.md
    practices-audit.md
    INDEX.md
  full-sweep/
    plan-stores.md
    plan-machines.md
    plan-hooks.md
    plan-modules.md
    plan-main.md
    plan-e2e.md
    findings/
      ...
    parity-gaps.md
    practices-audit.md
    INDEX.md
```

### Finding file structure

```markdown
---
id: 001
spec: e2e/pdf-warm-restore.spec.ts
status: open | confirmed | rejected | fixed
created: 2026-05-20
---

## Bug Summary
What's wrong, where, expected vs actual. One paragraph.

## Reproduction
Test file + line numbers. Failing assertion. How to run it.

## Tester Analysis
Why this is a production bug, not a test problem.

## Reviewer-1 Verdict: CONFIRM | REJECT
Reasoning. If REJECT: what would change their mind.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
(Only present if Reviewer-1 rejected.)

## Tiebreaker Verdict: CONFIRM | REJECT
(Only present if rebuttal disputes.) Binding.

## Fix Plan
TDD plan: red test → minimal change → refactor.

## Code Review
Approve / request changes.

## Coder Rebuttal
(If review requested changes.)

## Final Verdict
Linked commit SHA + verified test pass.
```

### INDEX.md

A status board the orchestrator updates after every wave. Columns: id, spec, status, reviewer outcome, fix commit, verified.

## Pilot Workflow

Scope:

- `e2e/pdf-warm-restore.spec.ts` ↔ `src/renderer/src/stores/pdfStore.test.ts`
- `e2e/epub-warm-restore.spec.ts` ↔ `src/renderer/src/stores/epubStore.test.ts`
- `e2e/azw3-real-import-routing.spec.ts` (warm subset)
- `e2e/mobi.spec.ts` (warm subset) + `src/main/ipc/__tests__/formats-mobi.test.ts`

Waves:

| Wave | Parallelism | Agents | Output |
|---|---|---|---|
| 1. Plan | 1 | `team-planner` | `.agent-review/pilot/plan.md` |
| 2. Triage | 4 parallel | `team-tester` × 4 | finding files + `parity-gaps.md` + `practices-audit.md` |
| 3. Reviewer-1 | N parallel (1 per finding) | `team-reviewer` | CONFIRM/REJECT section appended |
| 4. Rebuttal | parallel (1 per rejected) | `team-tester` | ACCEPT-REJECTION or REBUT section appended |
| 5. Tiebreaker | parallel (1 per disputed) | `feature-dev:code-reviewer` | Binding verdict appended |
| 6. Fix | **sequential**, 1 per confirmed | `team-coder` → `team-reviewer` → optional rebuttal → optional tiebreaker | Red test, fix, commit per finding |
| 7. Summary | 1 | orchestrator | `INDEX.md` finalized; report to user |

### Parallelism rationale

- Triage (wave 2) is read-only — no file conflicts possible — so fully parallel.
- Reviewer / rebuttal / tiebreaker (waves 3-5) operate on independent finding files — parallel.
- Fixes (wave 6) write to the codebase and could conflict if two coders touched the same module simultaneously — strictly sequential, one atomic commit per finding.

### Safety rails

- One tester rebuttal max per finding, then forced tiebreaker. No loops.
- One coder rebuttal max per fix, then forced diff tiebreaker.
- If a coder's fix breaks an unrelated test, they revert and re-plan rather than fix-on-fix.
- If an agent reports the plan or finding is incoherent, the orchestrator pauses and surfaces it to the user.
- INDEX.md tracks running agent count; orchestrator stops to check in if dispatch count exceeds rough budget (~30-60 for pilot, ~200-250 for full sweep).

## Full Sweep Workflow

Same agent roles, same file layout, same safety rails. Differences from pilot:

- **Plan parallelism:** Wave 1 splits into ~6 area-plans (stores, machines, hooks, modules, main, e2e), generated in parallel.
- **Triage batching:** Wave 2 runs ~10-15 testers in parallel, batched by area.
- **Triage gate:** Before wave 6 (fix), the orchestrator presents `INDEX.md` to the user. User decides which confirmed bugs are fixed this run vs. tracked for later. Reason: full sweep may surface 30+ confirmed bugs; user may want to scope.
- **Pilot lessons:** if the pilot exposes a workflow defect (e.g., rebuttal loop always rubber-stamps), design is adjusted before scaling.

## Test-Authoring Principles (Planner Guidance)

The planner writes these principles into `plan.md` and the testers apply them:

- **Real over mocked** at boundaries. Don't mock the SQLite database; use a temp file. Don't mock `fs`; use a tempdir. (Per repo convention.)
- **Behavior over implementation.** Assert on outputs, file contents, user-visible state — not on private methods or call counts.
- **No flake-prone timing.** Use Playwright auto-waits, Vitest `await` patterns. No `setTimeout` in assertions.
- **Format parity** where parity is meaningful. Warm-restore, persistence, scroll-position, import routing should exist for every supported format unless a format genuinely doesn't support that capability.
- **Test independence.** No shared state between tests. Setup creates, teardown destroys.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Reviewers rubber-stamp everything → no rejections → wasted process | Pilot specifically validates this; if all 4 testers report 100% confirm rate, halt and inspect. |
| Two coders edit overlapping files (full sweep) | Wave 6 is strictly sequential. |
| Agent budget runs away | INDEX.md tracks count; orchestrator pauses past budget thresholds. |
| Findings file format drifts across agents | Planner produces a finding-file template that testers/reviewers copy from. |
| A "bug" is actually a deliberate design choice undocumented in code | Reviewer-1's job to catch; tiebreaker is the safety net. |
| Pilot succeeds but full sweep finds 50+ bugs we can't fix this cycle | Triage gate lets user scope; unfixed confirmed bugs stay in INDEX.md as a backlog. |

## Success Criteria

**Pilot succeeds when:**

- All 4 specs triaged, finding files written, dialog completed for every disputed finding.
- Reviewer outcomes are non-trivially mixed (i.e., not 100% CONFIRM or 100% REJECT — that would suggest the reviewer isn't doing real work).
- Every CONFIRMED bug has a fix commit with a passing test.
- `INDEX.md` is a complete audit trail.
- Workflow is judged sound enough to scale to full sweep.

**Full sweep succeeds when:**

- All test files in `apps/rishi-electron` are triaged.
- Parity gaps and practice violations are documented even when not fixed.
- User-approved subset of confirmed bugs is fixed with passing tests and atomic commits.
- Unfixed-but-confirmed bugs remain in INDEX.md as a tracked backlog.
