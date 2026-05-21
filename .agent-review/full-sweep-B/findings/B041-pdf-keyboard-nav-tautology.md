---
id: B041
spec: e2e/pdf-reader.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The test `"keyboard navigation does not crash"` (pdf-reader.spec.ts L49-55) presses `ArrowRight` then `ArrowLeft` and asserts only `expect(bookPage.locator('body')).toBeVisible()` (L54). Body visibility is tautologically true for any non-crashed renderer — it returns true even if the Arrow handlers are completely unbound, the focus is on a stale window, or the keyboard event never reaches the PDF reader at all. The test's name implies "navigation works"; its assertion delivers "renderer didn't whitescreen". A real production regression — Arrow keys becoming no-ops in the PDF window after the Phase-3 per-book-window split — would not be caught.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-reader.spec.ts` lines `49-55`
- Failing assertion (current, tautological): `await expect(bookPage.locator('body')).toBeVisible()`
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm test:e2e e2e/pdf-reader.spec.ts -g "keyboard navigation does not crash"
  ```

## Tester Analysis
Phase-3 split moved the reader into a separate BrowserWindow with its own renderer. Any global `keydown` listener registered on the library window no longer receives events for the reader; reader-side listeners must be re-bound in the reader window. If that wiring regresses, the user-visible symptom is "Arrow keys do nothing in the PDF reader" — exactly the bug this test's name targets, but its assertion cannot detect.

A meaningful assertion would observe an effect of ArrowRight: page index changes via `getBookLocation(app.page, bookId)`, or `scrollTop` of `div.overflow-y-scroll` increases, or the visible page-number indicator increments. The test already has `bookPage` and `app.page` in scope; reading book location before and after is two lines.

Finding-worthy (not just practice) because:
1. The test name makes a behavioral claim ("navigation") that the assertion does not verify.
2. The Phase-3 window split is a concrete, recent refactor whose regressions this test should catch.
3. `body` visibility checks are an established anti-pattern in this repo (pilot flagged the same at `mobi.spec.ts:40`).

## Reviewer-1 Verdict: CONFIRM (Class A)
**Agent type:** team-reviewer
**Flake check:** N/A (assertion is deterministic tautology, not flake-prone)
**Reasoning:** pdf-reader.spec.ts:54 asserts only `locator("body").toBeVisible()` after ArrowRight/ArrowLeft (L50-52); body visibility holds for any non-crashed renderer and cannot detect arrow-key handlers being unbound in the Phase-3 split reader window. Helper `getBookLocation` (electron-app.ts:233) is already imported-adjacent and would give a real before/after page-index assertion in 2 lines.
**Suggested fix scope:** Capture `getBookLocation` before ArrowRight, assert it changes after, then returns after ArrowLeft.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** 625a2b6ed7bac23dfe065e26ecd2463212193bc5
**Notes:** Replaced `locator('body').toBeVisible()` after ArrowRight/ArrowLeft with `expect.poll` over the page index extracted from `getBookLocation` (`page:offset` format). ArrowRight must increase the index; ArrowLeft must decrease it. Imported `getBookLocation` (already used by `pdf-persistence.spec.ts`). The Phase-3 reader-window arrow-handler binding regression class now fails the test instead of slipping past.
**E2E mutation check:** env-blocked (sandbox teardown timeout); typecheck passes.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
