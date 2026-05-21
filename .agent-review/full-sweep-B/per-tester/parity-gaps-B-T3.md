# Parity Gaps — B-T3 (PDF e2e)

Scope: `pdf-import.spec.ts`, `pdf-persistence.spec.ts`, `pdf-reader.spec.ts`.

Parity gaps are coverage holes where a sibling format (EPUB / MOBI / AZW3) has a test the PDF suite lacks, or where PDF has a known production capability with no exercising test. They are **not** findings (no production bug demonstrated).

---

## PG-T3-1: No `pdf-real-import-routing.spec.ts` analogue

- `importBook` is called in all three PDF specs with hardcoded `kind: 'pdf'` (`pdf-import.spec.ts:41`, `:74`; `pdf-persistence.spec.ts:17`; `pdf-reader.spec.ts:22`), dispatching directly to the PDF-typed import handler.
- AZW3 has `azw3-real-import-routing.spec.ts` that exercises the OS-open-file → mime-sniff → handler-selection path end-to-end.
- PDF has no equivalent. A regression in the importer's `.pdf` dispatch (mime detection, file-extension priority, encrypted-PDF rejection) would not be caught by any of B-T3's three specs.
- Pilot framing applies (re: `helpers/electron-app.ts` `importBook` dispatcher bypass for MOBI): same pattern, different format.

## PG-T3-2: PDF reader cache (`window.__readerCache.pdf`) is never asserted

- Pilot §2.1 noted PDF's cache diagnostic is unused.
- Repeats in `pdf-persistence.spec.ts`: after `closeBook` + `openBook` (L40-47), the spec asserts the page location restores but never verifies the cache served the reopen (vs a cold re-fetch from disk).
- A cache regression (cold re-decode on every reopen, defeating the cache's purpose) would not be caught.

## PG-T3-3: No assertion that ErrorBoundary is absent on cold open

- Pilot §2.2 raised the same asymmetry for EPUB.
- `pdf-import.spec.ts` "PDF imports, opens, and renders pages" (L38-56) never asserts the reader window is free of error fallback markup. A regression that mounts the ErrorBoundary fallback (e.g. failed PDF.js worker init) on a valid PDF could co-exist with the current `toBeAttached('div.overflow-y-scroll')` assertion if the boundary itself uses a scroll container.

## PG-T3-4: PDF reader window has no visible-page assertion

- EPUB sibling at `pdf-import.spec.ts:65` asserts `[aria-label="Next page"]` — a real content marker.
- PDF reader has no equivalent visible-content locator anywhere in B-T3 scope.
- See finding B031 — coverage gap promoted to finding because the test name promises page rendering.

## PG-T3-5: No flake-tolerance run for persistence

- `pdf-persistence.spec.ts` runs once with hardcoded `waitForTimeout(3000)` settle pauses (L22, L48). The pilot's "live parity baseline" framing implies repeated runs should be stable.
- Plan §4 documents a 3-run flake check but the spec itself has no internal retry-on-stable-state pattern. Document for test-infra to absorb.

---

Total parity gaps: 5. None promoted to findings except where explicitly noted (B031 only).
