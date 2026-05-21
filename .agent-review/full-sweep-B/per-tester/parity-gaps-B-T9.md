# Parity Gaps — B-T9 (smoke, no-toolbar, mobi-global-page-counter, scanner)

Tester: B-T9
Slice: 4 specs (1 infra-smoke + 3 misc-light)
Date: 2026-05-20

Each entry: untested behavior that a parity test would cover. Out of
scope for `findings/` (no concrete production bug demonstrable from the
spec alone) but worth tracking for follow-up coverage work.

---

## PG-T9-01 — `no-toolbar.spec.ts` covers only PDF reader window

- Spec: `apps/rishi-electron/e2e/no-toolbar.spec.ts:4-15`
- Gap: only the PDF reader is exercised. EPUB, MOBI, and AZW3 reader
  windows could each still ship a stray `[data-tour="reader-toolbar"]`
  and this spec would not catch it. The phase-2 design (no in-window
  toolbar) is a window-shell contract, not a PDF-only one.
- Suggested coverage: parametrize across `{PDF_FIXTURE, EPUB_FIXTURE,
  MOBI_FIXTURE, AZW3_FIXTURE}` with one assertion each — or a single
  test that opens all four and asserts `count() === 0` per window.

## PG-T9-02 — `no-toolbar.spec.ts` asserts absence only, no positive check

- Spec: `apps/rishi-electron/e2e/no-toolbar.spec.ts:10-11`
- Gap: `expect(count).toBe(0)` against `[data-tour="reader-toolbar"]`
  silently passes forever if the selector is renamed in prod. There is
  no positive companion assertion that *something else* (the menu-bar
  replacement, the page nav controls, etc.) actually rendered.
- Suggested coverage: pair with `await expect(page.locator(
  '[data-testid="reader-menubar"]')).toBeVisible()` (or whichever
  element is the phase-2 replacement surface).

## PG-T9-03 — `mobi-global-page-counter.spec.ts` has no back-direction test

- Spec: `apps/rishi-electron/e2e/mobi-global-page-counter.spec.ts:53-83`
- Gap: only forward Next-click traversal is exercised. The symmetric
  invariant — Prev from page `N+1` returns to `N`, including across
  chapter boundaries — is uncovered. Reverse traversal across chapter
  boundaries is a distinct code path (often computed differently from
  forward) and a likely site for a parallel regression.
- Suggested coverage: after the existing forward loop reaches
  `chapterCrossings >= 1`, run a Prev loop of equal length and assert
  the counter decrements by exactly 1 each click.

## PG-T9-04 — `scanner.spec.ts` does not assert scan results render

- Spec: `apps/rishi-electron/e2e/scanner.spec.ts:40-46`
- Gap: only the *scanning indicator* is asserted. The full
  scan → results list → "Import these" path is uncovered. The IPC
  could return zero results, malformed results, or hang after the
  indicator paints, and all three tests would still pass.
- Suggested coverage: against a fixture directory containing one
  known book, assert the results list renders an entry whose name
  matches the fixture and the Import action enqueues the book into
  the library.

## PG-T9-05 — `scanner.spec.ts` has no mid-scan cancel test

- Spec: `apps/rishi-electron/e2e/scanner.spec.ts:48-59`
- Gap: Cancel is tested only *before* the scan begins (when the modal
  has just opened). Cancel *while scanning* is a different code path
  — open file handles, in-flight IPC, the indicator itself — and is
  the more bug-prone surface (handle leaks, orphaned worker, late
  results updating closed state). Uncovered.
- Suggested coverage: start a scan, await the indicator visible, then
  click Cancel and assert (a) modal closes, (b) no late toast/error
  fires within 2s, (c) re-opening the modal shows a clean state.
