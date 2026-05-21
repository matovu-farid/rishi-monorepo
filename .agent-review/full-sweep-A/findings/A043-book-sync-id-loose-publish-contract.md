---
id: A043
spec: apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The "does not publish bookmarks when the sync id is null/empty" test
(lines 68-78) uses `await new Promise(r => setTimeout(r, 0))` to "flush"
microtasks, then immediately asserts `publishBookmarksToMenu` was not called
and `result.current.bookSyncId === ''`. Three issues:

1. **Negative-assertion-after-setTimeout(0) is unsound.** If
   `publishBookmarksToMenu` is invoked inside a chained `.then` deeper than
   one microtask tick, the assertion passes incorrectly and the regression
   slips through. The test cannot prove "never called" with a single tick.
2. **Empty-string contract is brittle.** Asserts the hook normalizes `null`
   to `''`. But the production type signature says `bookSyncId: string` and
   `bookSyncIdRef: RefObject<string | null>` (lines 16-19). If production
   sets the ref to `null` for null inputs, the state assertion (`=== ''`)
   passes only because state was *initialized* to `''` and the hook bails
   out — i.e. the test does not actually verify the contract "null input
   → empty state", it verifies "the initial state value happens to be ''".
3. **No test for bookId change.** If `useBookSyncId(7)` is followed by a
   re-render with `useBookSyncId(8)`, the hook should re-publish bookmarks
   for the new sync id — but the test never exercises that re-mount.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts` lines `68-78`
- Failing assertion: `expect(publishBookmarksToMenu).not.toHaveBeenCalled()` at line 76
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts`

## Tester Analysis
Recommended remediation:
- Replace `setTimeout(0)` flushing with `await waitFor(...)` paired with a positive assertion (e.g. wait until `result.current.bookSyncId` settles, then assert publish was NOT called).
- Add a positive baseline test that asserts initial `bookSyncId === ''` BEFORE the promise resolves; only then is the "remains empty after null resolves" assertion meaningful.
- Add a re-render test with a new bookId to lock the re-publish contract.

Production file: `apps/rishi-electron/src/renderer/src/hooks/reader/useBookSyncId.ts`.

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** team-reviewer
**Flake check:** 5/5 pass — vitest run repeated 5 times, all green (durations 398–495ms). No flake.
**Reasoning:**
- Production hook `apps/rishi-electron/src/renderer/src/hooks/reader/useBookSyncId.ts:25-32` only has ONE chained `.then` for the null path, and the falsy branch (`if (syncId) setBookSyncId(...)`) means the second effect never fires. A single `setTimeout(0)` flush IS sufficient here, so claim #1's "negative-assertion-after-setTimeout(0) is unsound" does not mask any actual bug in this hook's current shape — it is brittle (would break under a future refactor that adds an extra microtask), but not currently incorrect.
- Claim #2 is accurate: `bookSyncId` is initialized to `''` at line 23, and the null branch never calls `setBookSyncId`, so `expect(result.current.bookSyncId).toBe('')` at test line 77 cannot distinguish "stayed at initial value" from "actively normalized to ''". This is a contract-coverage gap, not a bug — the observable behavior is identical.
- Claim #3 is accurate and the most material: the hook's effect deps include `[bookId]` (line 32), so a re-render with a new `bookId` should re-fetch and re-publish. No test exercises this re-render path, so the dep array could be silently changed to `[]` without test failure. This is missing coverage.
- No production bug; production code at `useBookSyncId.ts:22-39` is correct. Findings are about test robustness and missing coverage.

**Suggested fix scope (if A or B):** Add a re-render test that changes `bookId` and asserts `booksGetSyncId` is re-called and bookmarks re-published; replace `setTimeout(0)` flush with a `waitFor` on a positive signal (e.g., `electron().booksGetSyncId` resolved) before the negative assertion.


## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
