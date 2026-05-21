---
id: B104
spec: e2e/import.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
The three parser tests in `import.spec.ts` (L28-55) call
`electron.getPdfData`, `electron.getBookData`, `electron.getMobiData`
directly on the renderer. They never traverse the production import
pipeline (`open-file` → renderer `open-files` IPC → `useFileOpenHandler`
→ `getBookImportService().importBatch` → dispatch → format IPC →
`saveBook`) that the `importBookViaOpenFile` helper exists to drive
(see `e2e/helpers/electron-app.ts:128-178`). The `kind: 'pdf'` /
`'epub'` / `'mobi'` asserted at L34/L44/L54 is the *parser's* return
value, not the *dispatcher's* routing decision. This is the exact bug
class that `azw3-real-import-routing.spec.ts` was written for after
pilot 011, and there is no PDF / EPUB / MOBI equivalent of that spec.
A regression where, for example, `.epub` files are dispatched as
`kind: 'pdf'` (extension lookup table inversion, hash-prefix sniffer
swap) would pass this entire file.

## Reproduction
- Test file: `apps/rishi-electron/e2e/import.spec.ts` lines `28-55`
- Failing assertion: assertions present but cover the wrong contract;
  the failing test that *should* exist is "importing a fixture via the
  OS open-file event produces a saved book whose persisted `kind`
  matches the fixture extension".
- How to run:
  ```
  cd apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/import.spec.ts
  ```

## Tester Analysis
The dispatch path is where the real routing bugs live. Production
incident pattern (per pilot 011 / azw3 spec context): a file lands in
`open-file`, the dispatcher inspects extension/magic bytes, picks the
wrong format IPC, the parser dutifully returns *its* format's `kind`,
and the book is persisted with a mismatched kind that breaks the reader
when opened. The current parser tests cannot catch this because they
*supply* the parser directly — by construction the parser returns its
own kind.

The fix is structural: add `pdf-real-import-routing.spec.ts`,
`epub-real-import-routing.spec.ts`, `mobi-real-import-routing.spec.ts`
that each call `importBookViaOpenFile(launched, FIXTURE)` and then
assert `getBookKind(page, bookId) === '<expected-format>'`. The helper
already exists; only the specs are missing.

This is filed as a finding (not a parity-gap note) because the missing
coverage maps to an active class of production regressions that has
already shipped at least once.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (missing-coverage finding, no failing test to re-run)
**Reasoning:** Verified `import.spec.ts:28-55` calls `e.getPdfData/getBookData/getMobiData` directly on the renderer, asserting the parser's own `kind` field — these are tautological for dispatch-routing purposes. `e2e/helpers/electron-app.ts:138-178` defines `importBookViaOpenFile` to drive the real `app.emit('open-file', …)` → `useFileOpenHandler` → `BookImportService.importBatch` → `dispatchFormatExtraction` → `saveBook` path. `grep importBookViaOpenFile e2e/` shows the helper is consumed by only `azw3-real-import-routing.spec.ts` — no PDF/EPUB/MOBI counterparts exist. Unit coverage at `src/renderer/src/services/book-import/dispatch.test.ts` exists but uses stub `FormatsIpc`, so a swap between the real preload extension table and IPC handlers (the exact AZW3-pilot-011 regression class) would still pass. Coverage gap is real and matches a shipped incident pattern.
**Suggested fix scope:** Add three thin specs (`pdf-real-import-routing.spec.ts`, `epub-real-import-routing.spec.ts`, `mobi-real-import-routing.spec.ts`) mirroring `azw3-real-import-routing.spec.ts`, each calling `importBookViaOpenFile(launched, FIXTURE)` then asserting `getBookKind(page, bookId) === '<ext>'`.
