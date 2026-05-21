# Parity Gaps — Tester B-T2 (EPUB e2e batch)

Scope: 4 specs — `epub-cache-no-flash.spec.ts`, `epub-first-open.spec.ts`,
`epub-reader.spec.ts`, `epub-text-selection.spec.ts`.

## PG-T2-01 — `importBook(...)` hardcodes `kind: 'epub'` in all 4 specs

| Spec | Lines |
|---|---|
| epub-cache-no-flash | L37–41 |
| epub-first-open | L28–32 |
| epub-reader | L19–23 |
| epub-text-selection | L61–65 |

Hardcoding the kind bypasses the real importer dispatcher entirely. None
of the four specs exercises the production code path that infers `kind`
from file extension / mime-sniff. A regression in the dispatcher that
misroutes EPUB to a different reader would not be caught by any EPUB
e2e. **Recommended spec:** `epub-real-import-routing.spec.ts` — drives
import via the actual file-open IPC (`importBookViaOpenFile`) on the
EPUB fixture, asserts the resulting book record has `kind === 'epub'`
and that `openBook(...)` mounts the EPUB reader (not PDF / not MOBI).
Same pattern flagged in pilot finding 011.

## PG-T2-02 — Zero CFI / location-restoration coverage across all EPUB specs

None of the four specs read or assert a CFI or chapter-location signal.
`pdf-persistence.spec.ts` has direct precedent for asserting page-state
round-trip; EPUB has nothing equivalent. Concretely missing:
- After Next/Prev/keyboard navigation in `epub-reader.spec.ts`, no test
  asserts the location moved (cf. finding B017).
- No warm-restore or window-close-and-reopen test asserts the previous
  CFI is restored. The skipped `epub-cache-no-flash.spec.ts` explicitly
  omits this even though it owns the warm-restore flow (plan §2.1 last
  bullet).

**Recommended spec:** `epub-cfi-persistence.spec.ts` — open EPUB, click
Next twice, read CFI via `__readerCache.epub` surface, close book
window, reopen, assert CFI equals previous value within tolerance.

## PG-T2-03 — `__readerCache.epub.stats()` (hits/misses) unverified outside the skipped spec

`epub-cache.ts:40` exposes `stats()` symmetrically with `pdf-cache.ts`,
but only the skipped `epub-cache-no-flash` spec touches the `epub` cache
surface (and only via `has()`, not `stats()`). The cache invariant
"second open is a hit, not a miss" has no active test. PDF has
equivalent coverage in its own cache specs (out-of-scope for this
batch, but the asymmetry is the gap).

**Recommended spec:** `epub-cache-hit-stats.spec.ts` — import, open
once, close book window, reopen, assert `__readerCache.epub.stats()`
shows hits incremented and misses unchanged.

## PG-T2-04 — No EPUB e2e exercises `importBookViaOpenFile` (real OS-dispatch)

All four specs go through the `importBook(page, { fixturePath, kind, title })`
helper, which writes the file into the library via a programmatic IPC
shortcut. No EPUB spec exercises the actual `importBookViaOpenFile`
helper that drives the file-open dialog handler. A regression in the
OS-dispatch import flow (mime detection, drag-drop wiring, sandbox path
handling) would not be caught for EPUB.

**Recommended spec:** add an opt-in `epub-import-via-open-file.spec.ts`
(behind a `test.describe.serial(...)` or a tag) that invokes the dialog
handler and asserts the book lands in the library with `kind === 'epub'`.

## PG-T2-05 — TOC behavior is only conditionally tested

`epub-reader.spec.ts` L50–57 is the only TOC test in the EPUB batch, and
it auto-skips when the selector is missing (finding B018). There is no
companion test verifying TOC content (chapter list, click-to-navigate).
**Recommended spec:** `epub-toc-navigation.spec.ts` — open EPUB, toggle
TOC, assert at least one chapter entry, click it, assert location
changed (ties into PG-T2-02).

---

**Summary:** 5 parity-gap entries, all driven by the EPUB e2e batch being
structurally testing-only (mount + smoke) without behavior assertions on
location, cache stats, or real dispatch paths.
