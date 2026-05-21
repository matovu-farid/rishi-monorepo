---
id: B074
spec: e2e/menu-recent.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-recent.spec.ts` line 46 asserts the Open Recent submenu contains
"Recent A" via `recent?.submenu?.some((m) => m.label === 'Recent A')`.
`.some()` returns true even if "Recent A" appears two, three, or N
times. A real bug in the recent-files manager — failing to dedupe when
the same book is imported twice, or appending instead of promoting on
re-open — would surface as duplicated submenu entries and would not be
caught by this assertion. Expected: there is *exactly one* "Recent A"
entry in the submenu; actual: the test accepts any non-zero count of
matching entries.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-recent.spec.ts` lines `44-46`
- Failing assertion (current): `expect(recent?.submenu?.some((m) => m.label === 'Recent A')).toBe(true)`
- Missing assertion: `expect(recent?.submenu?.filter((m) => m.label === 'Recent A').length).toBe(1)`
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/menu-recent.spec.ts
  ```

## Tester Analysis
Dedup logic in recent-files lists is a classic LRU pitfall: the naive
implementation appends on every "remember this file" call, which makes
re-opening a book duplicate it rather than promote it. The test was
designed to verify Open Recent reflects imported books, but its
assertion shape gives no protection against duplicates. Strengthening
the assertion to count occurrences is free (no new fixtures, no
re-architecture). Plan (`plan-menu-B.md` §2.3 bullet 5) calls this out
as a Practice violation. Note: the broader parity gap (importing N≥3
books and asserting LRU order) is filed under
`parity-gaps-B-T6.md`; this finding scope is narrowly the dedup
blind-spot already exercised by the single-book test.

## Reviewer-1 Verdict: A
**Agent type:** general-purpose
**Flake check:** N/A (static review of assertion shape)
**Reasoning:** `e2e/menu-recent.spec.ts:46` asserts `recent?.submenu?.some((m) => m.label === 'Recent A')`, which returns true for any count ≥1. `src/main/database/queries.ts:144` selects recent books by `ORDER BY id DESC` with no GROUP BY / DISTINCT on title, so a re-import that creates a second `books` row with the same title would yield two "Recent A" entries — undetected by `.some()`. Strengthening to `.filter(...).length === 1` is free and aligns with `plan-menu-B.md` §2.3 bullet 5.
**Suggested fix scope:** Replace the `.some()` assertion with an exact-count `.filter(...).length === 1` check on "Recent A".

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
status: fixed
commit: 88cdf8bc
notes: Replaced `recent?.submenu?.some((m) => m.label === 'Recent A')` with
`recent?.submenu?.filter((m) => m.label === 'Recent A').length === 1`. The
single-book test now fails (loudly) on any dedup regression that produces
two or more "Recent A" entries, while still failing on the original
zero-entries regression. No production code changed. Typecheck green.

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
<append after wave 7>

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
