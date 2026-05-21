---
id: B047
spec: e2e/pdf-scroll-position.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
After reopen, the test only inspects `scrollTop` (L65-68). It never
asserts which PDF page is actually displayed. A right-pixel /
wrong-page bug — e.g. a 1-off page-index error that the virtualizer
happens to render at a numerically similar `scrollTop` because pages
have similar heights — would pass. Users would see "page 6" instead of
"page 5" but the test would call it green.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-scroll-position.spec.ts` lines `65-81`
- Failing assertion (gap, not a bad assertion): no
  `expect(displayedPage).toBe(savedPage)` check.
- How to run:
  ```bash
  cd apps/rishi-electron
  pnpm test:e2e e2e/pdf-scroll-position.spec.ts
  ```
- Mutation probe: in the restore path, force `pageIndex - 1`. If page
  heights are roughly uniform in the fixture, the absolute `scrollTop`
  delta may be within the ±450px tolerance from B046; the test passes
  while showing the wrong page.

## Tester Analysis
The persisted format is `page:offset` (verified at L49 via the regex
`/^\d+:\d+/`). The save side is therefore covered. The restore side
should also be covered at the same granularity: pull the page number
out of e.g. `[data-page-number]` on the visible `react-pdf__Page` or
the page label rendered in the PDF toolbar, and assert it equals
`Number(savedLocation.split(':')[0])`. Currently the only restore
assertion is on raw scroll pixels, which is the wrong layer of
abstraction for a "did we land on the same page?" check. This is a
coverage gap on the integration seam between persistence and
virtualizer scroll-to-page.

## Reviewer-1 Verdict: B
**Agent type:** team-reviewer
**Flake check:** N/A (gap, not flake)
**Reasoning:** Spec L65-81 only reads `scrollTop` with ±450px tolerance; never queries `[data-page-number]` (available per src/renderer/src/components/pdf/components/pdf.tsx:801) to assert displayed page matches `Number(savedLocation.split(':')[0])`. A 1-off page index restoring at a numerically similar scrollTop would pass. Real coverage gap on the persistence/virtualizer-scroll seam, not a bug in product code.
**Suggested fix scope:** Add a page-index assertion after restore using `[data-page-number]` to compare against the saved page from `savedLocation`.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** ada3ea2631be3b21234e2ddf0b3536d32e949353
**Notes:** After reopen, added a DOM query over `[data-page-number]` (emitted by `pdf.tsx:877`) that finds the page nearest the scroll container's viewport top and asserts its number equals `Number(savedLocation.split(':')[0])`. The previous ±450px scrollTop tolerance could mask a 1-off page error on uniform-height fixtures; the page-index assertion closes that. Kept the existing scrollTop tolerance check as the sub-page-offset signal.
**E2E mutation check:** env-blocked (sandbox teardown timeout); typecheck passes.
**Note on filename:** Finding header listed `pdf-scroll-position.spec.ts` (correct — matches the L49 `^\d+:\d+/` reference). Task description mentioned `pdf-persistence.spec.ts`; followed the finding body since it cites concrete line numbers and assertion shapes in scroll-position.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
