# Test-Infra Notes — B-T3 (PDF e2e)

Scope: `pdf-import.spec.ts`, `pdf-persistence.spec.ts`, `pdf-reader.spec.ts`.

Items affecting the e2e harness, fixtures, or runner; cross-cutting concerns that would require helpers-sweep coordination (per plan §1, do NOT directly audit `helpers/electron-app.ts`).

---

## TI-T3-1: PDF scroll-container needs a stable selector

Both `pdf-import.spec.ts:52` and `pdf-persistence.spec.ts:30` locate the PDF reader's scroll container via Tailwind class `div.overflow-y-scroll`. A repo-wide convention for the production element to expose `data-testid="pdf-scroll-container"` (or equivalent) would let both specs (and any future PDF spec) share a single locator. Helpers-sweep should consider adding a `pdfScrollContainer(page)` helper in `helpers/electron-app.ts` once the production attribute exists.

## TI-T3-2: `openBook` settle contract is implicit

All three specs follow `openBook` with `waitForTimeout(3000)` (pdf-persistence L22, L48; pdf-reader L34) — clearly a learned contract that the harness's `openBook` returns before the renderer is steady. Helpers-sweep should consider either:

- making `openBook` await a settle marker (e.g. first canvas visible for PDF, first paginated text node for EPUB) before resolving, OR
- exposing a typed `waitForReaderReady(bookPage, kind)` helper that callers can await deterministically.

Either eliminates 6+ `waitForTimeout(3000)` calls across the PDF suite alone.

## TI-T3-3: `closeBook` IPC has no helper

`pdf-persistence.spec.ts:40-44` inlines the IPC plumbing for `electron.closeBook(bookId)` via `page.evaluate` with a hand-rolled `window.electron` cast. This is the canonical close-the-reader-window IPC and will appear in every future per-window-split spec. Helpers-sweep should add `closeBook(libraryPage, bookId)` to `helpers/electron-app.ts`.

## TI-T3-4: `getBookLocation` returns `string | undefined` with no shape contract

Used at `pdf-persistence.spec.ts:26, 35, 49`. Tests parse the string format `<page>:<offset>` directly. A typed return (`{ page: number; offset: number }` or branded `BookLocation`) would let parsing happen once in the helper and let tests assert on `.page` directly — eliminating PA-T3-9.

## TI-T3-5: No PDF-specific fixture variants

The PDF suite uses a single `PDF_FIXTURE` (imported from helpers) for all three specs. No coverage of:

- multi-hundred-page PDFs (scroll-virtualization stress)
- encrypted PDFs (error path)
- PDFs with broken xref / damaged headers (PDF.js recovery path)
- PDFs with form fields or annotations (reader feature parity)

These belong to helpers/fixtures sweep, not B-T3 findings — recorded here so the helpers owner sees the demand.

## TI-T3-6: Flake-tolerance command is documented but not enforced

Plan §4 includes a 3-run flake check loop. Nothing in the CI config (out of B-T3 scope to verify) is known to enforce it. Recommend the test-infra owner add a `test:e2e:flake` script that runs the persistence spec N times and fails on any single failure.

## TI-T3-7: `app.page.reload()` between import and open is not abstracted

`pdf-import.spec.ts:44` and `:77` both use `app.page.reload()` to re-hydrate the library window state. If the production hydration timing changes, both specs regress in lockstep. A helper `reloadLibrary(app)` that awaits the book-grid being ready would centralize this — proposing for helpers-sweep.

---

Total test-infra items: 7. All forwarded; none are B-T3 findings.
