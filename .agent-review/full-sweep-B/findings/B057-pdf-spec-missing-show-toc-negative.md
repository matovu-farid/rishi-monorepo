---
id: B057
spec: e2e/menu-book-pdf.spec.ts
status: rejected
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-book-pdf.spec.ts` asserts the presence of PDF-only items
(`Show Thumbnails`, `Dual Page`) but never asserts that the EPUB-only
`Show TOC` is *absent* in PDF context. The symmetric negative assertion
that exists on the EPUB side (`Show TOC` present, PDF-items absent) is
missing on the PDF side. A regression in `menuBuilder.ts` that leaks
`Show TOC` into PDF context (a real production hazard — confirmed by
`src/main/menu/menuBuilder.ts:60-99` gating on `bookKind`) ships
undetected by this spec.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-book-pdf.spec.ts` lines `42-46`
- Failing assertion (missing — needs to be added):
  ```
  expect(findMenuItem(menu, ['View', 'Show TOC'])).toBeUndefined()
  ```
- How to run:
  `cd apps/rishi-electron && pnpm test:e2e e2e/menu-book-pdf.spec.ts`

## Tester Analysis
Format enablement parity table (from plan §2.2):

| Menu item       | PDF spec asserts | EPUB spec asserts |
|-----------------|------------------|-------------------|
| Show TOC        | (not checked)    | present           |
| Show Thumbnails | present          | absent            |
| Dual Page       | present          | absent            |

PDF's missing `Show TOC` negative is the asymmetric coverage gap. The
production gating lives in `menuBuilder.ts:71` (`Show TOC` is appended
only when `bookKind === 'epub'`). If a refactor (e.g. moving the
conditional out of the EPUB branch into an unconditional push) regressed
this, the PDF context would gain a Show TOC item that does nothing — and
no test in this suite would notice. The unit-level
`src/main/menu/menuBuilder.test.ts:117` does cover this for the
template-builder layer, but the e2e wiring (install → publish → focus →
rebuild) is *exactly* the integration seam where the regression has the
most opportunity to slip in.

## Reviewer-1 Verdict: INVALID
**Agent type:** team-reviewer
**Flake check:** N/A
**Reasoning:** Premise is factually wrong. menuBuilder.ts:67-77 appends Show TOC for any ctx.kind === "book" (outside the format==="epub" branch at line 97), so Show TOC is intentionally present in PDF context. Unit test menuBuilder.test.ts:121-126 confirms by using pdfCtx to assert Show TOC is defined+checked. The proposed assertion toBeUndefined() would fail against current intended behavior; there is no coverage gap, and the parity table in the finding mismatches the spec.
**Suggested fix scope:** None — close as INVALID.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
status: no-op (INVALID)
commit: n/a
notes: Reviewer-1 verdict is INVALID with "Suggested fix scope: None — close as
INVALID." The proposed `toBeUndefined()` for `Show TOC` in PDF context would
contradict actual menuBuilder behavior, which adds `Show TOC` for any
`ctx.kind === 'book'` (PDF and EPUB alike). No code change applied.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
