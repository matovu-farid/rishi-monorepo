# Skipped / fixme / todo tests (baseline)

## Unconditionally skipped (Phase 3 candidates for un-skip)

- e2e/epub-warm-restore.spec.ts:69 — `test.skip('first open populates the cache, second open hits it', ...)`
- e2e/epub-cache-no-flash.spec.ts:28 — `test.skip('warm-restore reopen does not flash the inner loading view', ...)`
- e2e/pdf-warm-restore.spec.ts:33 — `test.skip('reopening a PDF hits the warm-restore cache and renders pages', ...)`
- e2e/pdf-footer-detection.spec.ts:103 — `test.fixme('masked items live in the bottom band', ...)`

## Conditional runtime-guard skips (do not un-skip)

- e2e/navigation-history-epub.spec.ts:98 — `test.skip(true, 'no TOC toggle button found in this build')`
- e2e/navigation-history-epub.spec.ts:121 — `test.skip(true, 'no TOC entries available in the test fixture')`
- e2e/navigation-history-pdf.spec.ts:148 — `test.skip(true, 'test PDF has fewer than 3 pages — skipping TOC jump test')`
- e2e/navigation-history-pdf.spec.ts:228 — `test.skip(true, 'test PDF has fewer than 5 pages — skipping engagement resume test')`
- e2e/read-aloud-from-selection.spec.ts:97 — `test.fixme(true, 'No paragraphs published — fixture issue or renderer not settled')`
- e2e/read-aloud-from-selection.spec.ts:167 — `test.fixme(true, 'Player still in idle — INITIALIZE not fired yet')`
- e2e/read-aloud-from-selection.spec.ts:233 — `test.fixme(true, 'Could not create iframe selection — fixture/render issue')`
- e2e/epub-reader.spec.ts:59 — `test.skip(true, 'no TOC toggle in this build')` (inline `if ((await tocToggle.count()) === 0)`)
- e2e/menu-commands.spec.ts:66 — `test.skip(true, 'bookSyncId could not be assigned for the imported PDF')`

## Other (it.skip in unit tests, describe.skip, etc.)

- (none)

Total: 4 unconditional, 9 conditional, 0 other
