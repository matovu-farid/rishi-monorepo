# Test Infra Backlog — Tester B-T4 (PDF Scroll Specs)

## Helpers to add / extend

1. **`waitForPdfReader(bookPage)` helper** in
   `apps/rishi-electron/e2e/helpers/electron-app.ts`. Polls until at
   least one `canvas.react-pdf__Page__canvas` is visible AND its
   parent reports non-zero measured height. Replaces the four
   `waitForTimeout(3000|4000)` cold-open / reopen waits across both
   specs.

2. **`waitForBookLocationSaved(page, bookId, predicate)` helper** that
   wraps `expect.poll(getBookLocation, ...)`. Removes the 1500ms wait
   at `pdf-scroll-position.spec.ts:44` and pins the assertion to the
   *observable* event (location string updated) rather than guessing
   listener-debounce-IPC budget.

3. **`waitForBookWindowClosed(app, bookId)` helper** polling
   `app.context().pages()` for absence of the book window. Removes
   the 1500ms post-close wait at L61.

4. **`getMountedPdfCanvasCount(page)` helper**. Needed to write the
   B051 precondition (assert pages-above-were-unmounted before
   scrolling back up).

5. **`getDisplayedPdfPageNumber(page)` helper**. Needed for B047 —
   page-index assertion after reopen. Source of truth: visible
   `react-pdf__Page` with the largest intersection ratio, or the page
   label rendered in the PDF toolbar.

## Test-data / fixture concerns

- `PDF_FIXTURE` height is implicitly assumed at three places
  (`scrollTo top: 6500`, `scrollTo top: 14000`, `scrollTop - 600`
  crosses a page boundary). A fixture swap would silently invalidate
  all three. Add a `PDF_FIXTURE_LAYOUT` constants block (page count,
  approx page height in px under default zoom) and reference those
  symbols from both specs.

## Selector stability

- Add `data-testid="pdf-scroll-container"` to the PDF reader's scroll
  div. Both specs `document.querySelector('div.overflow-y-scroll')`
  inside `page.evaluate`; switch to
  `document.querySelector('[data-testid="pdf-scroll-container"]')`.

## CI / flake observations

- Did not perform the 3x flake loop in the plan (§4) — out of tool
  budget for this static audit pass. Recommend running:

  ```bash
  cd apps/rishi-electron
  for i in 1 2 3; do pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts || echo "run $i: FAIL"; done
  ```

  before relying on the 80px threshold (B053) being tight enough.

## Out-of-scope but adjacent

- The `closeBook` IPC is invoked via inline `(window as unknown as
  { electron: ... }).electron.closeBook(id)` in
  `pdf-scroll-position.spec.ts:56-60`. Worth a typed helper next to
  `openBook` / `importBook` in `electron-app.ts`.
