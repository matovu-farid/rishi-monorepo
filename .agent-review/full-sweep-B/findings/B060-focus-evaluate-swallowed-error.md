---
id: B060
spec: e2e/menu-book-epub.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
All three specs (`menu-book-epub`, `menu-book-pdf`,
`menu-bookmarks-submenu`) call `launched.app.evaluate(...)` to focus the
book window and silently swallow the failure with `.catch(() => {})`. If
the focus call throws (e.g. because the URL substring match `/books/${id}`
no longer matches the renderer's actual URL after a router refactor),
the menu rebuild on focus never happens, and the subsequent
`getApplicationMenu(...)` reads the *previous* (Library) menu — which
happens to contain neither `Show TOC` nor `Show Thumbnails`. The PDF
spec then fails loudly (`Show Thumbnails` undefined), but the EPUB spec
*passes* vacuously (Library menu also has neither `Show Thumbnails` nor
`Dual Page`, and may happen to satisfy the top-level `arrayContaining`
on Bookmarks/Reader if those are global). The asymmetric failure mode
hides a real wiring regression behind a swallowed error.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-book-epub.spec.ts` lines `28-40`
  (also `menu-book-pdf.spec.ts:27-39` and
  `menu-bookmarks-submenu.spec.ts:44-51` — the latter doesn't even have
  the `.catch` but the URL match is still load-bearing)
- Failing assertion: any subsequent `findMenuItem(...)` call presumes
  focus succeeded
- How to run:
  `cd apps/rishi-electron && pnpm test:e2e e2e/menu-book-epub.spec.ts`

## Tester Analysis
`electronApplication.evaluate` rejects when the first webContents is
navigating (this is exactly why the spec has the `waitForTimeout(500)`
"settle" on L27 and the `.catch` on L40). The pragmatic shape is fine,
but swallowing the rejection means the test can't distinguish "focus
succeeded, menu is wrong" from "focus failed, menu was never rebuilt".
The fix is to either (a) propagate the rejection and let the test fail
with a clear message, or (b) assert post-condition (`BrowserWindow.find
... isFocused() === true`) after the catch so a swallowed error still
trips an explicit assertion. Today, finding B056 + a focus-rejection
combine into a silent pass — two bugs cancelling out.

This is filed against the EPUB spec but the same shape exists in all
three. One finding covers the pattern; cross-spec deduplication noted.

## Reviewer-1 Verdict: BUG-B
**Agent type:** general-purpose
**Flake check:** N/A (static code review of swallowed-error pattern)
**Reasoning:** Verified at `e2e/menu-book-epub.spec.ts:28-40`, `e2e/menu-book-pdf.spec.ts:27-39`, and `e2e/menu-bookmarks-submenu.spec.ts:44-51`. The first two wrap `launched.app.evaluate(...)` in `.catch(() => {})`, fully swallowing rejections from `electronApplication.evaluate` (Playwright rejects when the first webContents is navigating, which is exactly why the 500 ms settle exists on L27/L26). The bookmarks spec omits `.catch` but its in-evaluate `find(...).includes(url)` silently returns `undefined` on URL mismatch with no fallback to `wins[0]`, so a router refactor that changes the path shape would no-op the focus without throwing. Asymmetry is real: EPUB spec assertions on L45-46 (`Show Thumbnails`/`Dual Page` undefined) and the top-level `arrayContaining(['Bookmarks','Reader'])` on L48 can all be satisfied by the stale Library menu, so a swallowed focus failure passes vacuously; the PDF spec's L45-46 require these to be defined, so it fails loudly — exactly the asymmetric hide-a-regression pattern the finding describes. Test-hygiene defect masking real wiring regressions.
**Suggested fix scope:** Drop the `.catch(() => {})` (or assert `BrowserWindow.isFocused()` post-condition) in all three specs and remove the `wins[0]` fallback so URL-match failure surfaces as an explicit error.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
