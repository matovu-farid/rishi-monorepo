---
id: A034
spec: apps/rishi-electron/src/renderer/src/hooks/usePdfTextSelection.test.tsx
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
The cross-page guard test at `usePdfTextSelection.test.tsx:87-107` asserts
only that `onSelect` is NOT called when a Range spans pages 1 and 2. That
assertion *also* passes trivially if the hook fails to detect ANY selection
(e.g. its page-detection logic regresses to returning null for both pages,
or the `getClientRects` override silently no-ops under happy-dom — flagged
in plan §4 hooks-A as a brittle override). The test therefore does not
distinguish "hook correctly identified cross-page and bailed" from
"hook never even tried". Compounding this, the suite has 3 tests total for
a hook the plan calls "likely supports more options" — no scale != 1
assertion, no rotation, no scroll-during-selection, no onClear-after-
non-collapsed-then-collapsed sequence.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/usePdfTextSelection.test.tsx` lines `87-107`
- Failing assertion: n/a — the test passes; the issue is that it cannot
  fail for the documented bug class
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/usePdfTextSelection.test.tsx -t "ignores cross-page"`

## Tester Analysis
Two tightenings convert this from a trivially-passing guard test into a
behaviour-pinning test:

1. **Positive control inside the same test**: after asserting `onSelect not
   called` for the cross-page range, collapse the range onto page 1 and
   re-fire `mouseup`; assert `onSelect` IS called exactly once. This proves
   the bail was due to the cross-page condition, not a broken event loop.

2. **Assert onClear OR an internal warn**: production's actual contract on
   cross-page is either "silently bail" or "bail + log + onClear". The
   test should pin whichever is intended, otherwise a regression that
   starts firing `onSelect` with the wrong locator can be masked by
   reading the wrong page number from a Range that spans both.

Additionally — out of scope for findings, route to `parity-gaps.md` —
the hook needs tests for scale != 1, rotation, and scroll-during-selection
to match the breadth of `useUndoableHighlightShortcut`'s 7-keyboard-surface
coverage (plan §4 hooks-A reference).

## Reviewer-1 Verdict: TEST-QUALITY-A
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** N/A — this is a TEST-QUALITY finding (the test passes deterministically; the issue is what it *cannot* fail on). Single confirmation run: 1 passed.
**Reasoning:** Production hook `usePdfTextSelection.ts:46` enforces the cross-page guard via `startInfo.el !== endInfo.el`, so the assertion at test L106 (`expect(onSelect).not.toHaveBeenCalled()`) currently passes because the guard fires. However, the same assertion would also pass under at least four unrelated regressions: (1) `findPageInfo` returns null for either container (e.g. the `react-pdf__Page` class lookup at L22 breaks), (2) `getPageElement(startInfo.pageNumber) !== startInfo.el` at L48 short-circuits unrelatedly, (3) `getViewport` returns null (L50), or (4) `selectionToPdfLocator` returns null (L52). The test does not bind the bail to the cross-page branch specifically. Tester's recommendation #1 (positive-control: collapse range to page 1 and re-fire mouseup, then assert `onSelect` called exactly once with `locator.page === 1`) is the minimal tightening that pins behaviour. Recommendation #2 (assert `onClear` OR a warn) is also valid but requires deciding the contract first. No production bug — hook code is correct.
**Suggested fix scope (if A or B):** Add a positive-control assertion inside the same test: after cross-page mouseup, collapse selection onto page 1 only, re-fire mouseup, and assert `onSelect` was called exactly once with `locator.page === 1` — converts the trivially-passing guard into a behaviour-pinning test.

## Fix Plan
**Status:** fixed
**Commit:** 166591348e35acde5bac54dd2520630c662e2b1c
**Notes:** Added positive control after the cross-page assertion: collapses the selection onto page 1's text node, re-fires mouseup, and asserts `onSelect` called exactly once with `locator.page === 1`. Test now pins the bail to the cross-page branch rather than passing under any of the 4 unrelated regression modes documented above. Recommendation #2 (onClear/warn assertion) deferred — requires deciding the contract first.

## Code Review
**Verdict:** APPROVE
**Findings:** none
