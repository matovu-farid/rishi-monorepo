---
id: B046
spec: e2e/pdf-scroll-position.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
The restore-position assertion (L77-81) uses a flat ±450px tolerance on
absolute `scrollTop`. The intent is to confirm sub-page offset is
restored, but 450px is roughly the height of a half-page in the fixture.
A regression that silently snaps back to page-top (the old page-only
persistence behavior) for a saved offset of ~300-400px would still pass
this test — yet users would visibly lose their position. The test
cannot distinguish "restore works" from "restore is off by up to a
half-page" because tolerance was chosen to absorb virtualizer
measurement drift, not user-visible drift.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-scroll-position.spec.ts` lines `77-81`
- Failing assertion (currently passing, but blind to the regression):
  ```ts
  const tolerance = 450
  expect(scrollTopAfter).toBeGreaterThan(scrollTopBefore - tolerance)
  expect(scrollTopAfter).toBeLessThan(scrollTopBefore + tolerance)
  ```
- How to run:
  ```bash
  cd apps/rishi-electron
  pnpm test:e2e e2e/pdf-scroll-position.spec.ts
  ```
- Mutation probe: in pdfStore restore path, force `offset = 0` on
  reopen. Saved offset in this fixture is ~1100px (mid page), so a
  page-only restore would fall ~1100px short — that case the test
  catches. But a partial restore (offset clamped to 0-449px) is
  invisible.

## Tester Analysis
The production code path saves `page:offset` via
`books:updateLocation` (`apps/rishi-electron/src/main/ipc/books.ts:65`)
and restores it on reopen through the PDF reader's initial-scroll
effect. The test correctly checks that the *saved* string carries the
offset (L49), but the *restore* assertion only checks absolute scroll
position with a tolerance bigger than the offset values most users sit
at on a typical page. Recommended fix: assert exact page index match
(separate query: which `react-pdf__Page` is at viewport center?) and
keep the ±450px slack only for the within-page sub-pixel layout drift,
or shrink the tolerance to <150px now that the offset is persisted.
This is a test-design weakness that lets a real production regression
through; flagging here because the plan called it out as the most
likely real bug surface.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (test-design weakness, not flake)
**Reasoning:** Saved offset in fixture is ~1100px (test scrolls to 6500, scrollTopBefore > 6000; PAGE_HEIGHT=1540 in `apps/rishi-electron/src/renderer/src/components/pdf/utils/constants.ts:1` so 6500 ≈ page 5 + ~800px offset). Restore loop in `usePdfReader.ts:133-147` uses `virtualizer.scrollToOffset(pageStart + offset, ...)` with *measured* page offsets via `getOffsetForIndex`, polled at 100ms × 30 ticks until `visible === target`. Once landed, residual drift should be sub-page (tens of px, not hundreds), so a 450px window does mask a class of regressions: a restore that snaps to page-top for any saved offset 0–449px would still pass `expect(scrollTopAfter).toBeGreaterThan(scrollTopBefore - 450)`. However, the test's saved offset is intentionally ~800px past page-start (line 41 asserts >6000), which IS outside the 450px window from page-top, so a page-snap regression *here* would actually fail (scrollTopAfter would be ~5700 vs scrollTopBefore ~6500, delta ~800 > 450). The tester's framing overstates the gap: in this fixture the test does catch full page-snap. The legitimate concern is partial-snap (offset clamped to 0..449) and the tolerance > virtualizer drift would actually need. Real but narrow — Class B (test-quality nit, not a missed-regression bug).
**Suggested fix scope:** Tighten tolerance to ~150px and/or add a second assertion that the saved-offset round-trip matches within ~50px by re-reading the saved location after reopen.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
