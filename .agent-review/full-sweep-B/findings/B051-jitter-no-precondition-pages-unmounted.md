---
id: B051
spec: e2e/pdf-scroll-up-jitter.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The test's entire reason for existing is to exercise the
unmount → remount path (loading placeholder shrink → scroll shift →
visible jitter). But after `scrollTo({ top: 14000 })` (L45) it never
verifies pages above were actually unmounted before scrolling back up.
If virtualizer overscan ever grows, or the fixture grows page heights,
or the magic 14000 number stops crossing the unmount horizon, the
scroll-up never crosses a remount boundary — yet the assertion at L77
(`backJump < 80`) still passes (nothing to jitter against). The test
will silently stop guarding the regression it was written for.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-scroll-up-jitter.spec.ts` lines `42-48`
- Failing assertion (gap, not a bad assertion): no
  ```ts
  const mountedBefore = await bookPage.evaluate(
    () => document.querySelectorAll('canvas.react-pdf__Page__canvas').length
  )
  expect(mountedBefore).toBeLessThan(/* total pages in fixture */)
  ```
- How to run:
  ```bash
  cd apps/rishi-electron
  pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts
  ```
- Mutation probe: bump overscan in the PDF virtualizer so all pages
  stay mounted. Test still passes (no remount → no jitter to detect),
  but the original bug class is no longer being tested.

## Tester Analysis
This is a coverage-on-the-integration-seam gap: the unit-level
assertion is correct, but the precondition that the seam is being
exercised is implicit. The plan (`plan-pdf-B.md`, §2.2 "Gap") flags
this explicitly. Fix is small: query the mounted canvas count before
the scroll-up and assert at least one page that *will* be in view
after the scroll-up is currently unmounted. Same applies to verifying
top page count before the scrollTo. Without this, the test becomes a
no-op the day the implementation changes overscan from ~8 to "all".

## Reviewer-1 Verdict: B
**Agent type:** team-reviewer
**Flake check:** N/A (test-quality finding, no flake repro needed)
**Reasoning:** Spec L42-46 scrolls to top=14000 to force pages-above unmount, then L51-55 scrolls up 600px expecting a remount-driven jitter. No assertion verifies the precondition (any page unmounted before scroll-up, or that the scroll-up crosses a remount boundary). If overscan in the PDF virtualizer grows or fixture page heights change, the L77 `backJump < 80` check passes vacuously — no jitter to detect. Comment at L22-24 ("overscan only keeps ~8 pages mounted") is an implicit assumption, not enforced. Classify as B (test-coverage gap, not a runtime bug).
**Suggested fix scope:** Before the scroll-up, query `document.querySelectorAll('canvas.react-pdf__Page__canvas').length` and assert it is strictly less than total fixture pages; after the scroll-up settles, assert at least one canvas that was absent before is now present (remount actually occurred).

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** 78585f44711b69481342e8843ceb09799fd6d691
**Notes:** Added two preconditions around the existing scroll-up sampling. (1) After `scrollTo({ top: 14000 })`, capture mounted `[data-page-number]` values and assert the lowest mounted page is >1 (overscan really dropped pages above; this is the seam under test). (2) After the scroll-up sampling, assert at least one page whose number is below the prior-lowest is now mounted, proving a remount happened during the scroll-up — exactly the path the original jitter bug lives on. Used page-number set diffs rather than canvas counts to make the assertion direction-aware (remount *above*, not below).
**E2E mutation check:** env-blocked (sandbox teardown timeout); typecheck passes.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
