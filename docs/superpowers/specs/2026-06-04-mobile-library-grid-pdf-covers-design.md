# Mobile Library: 2-Column Grid + PDF Cover Extraction

**Date:** 2026-06-04
**Status:** Draft
**Owner:** matovu-farid

## Problem

The mobile Library screen renders books as a vertical list of rows (small letter-tile + title + author), but the design (Figma) calls for a 2-column grid of large book covers. In addition, PDF books always fall back to a letter-tile because mobile has no PDF cover extractor — only EPUB and MOBI are supported today.

This spec covers two coupled fixes: layout swap and PDF cover extraction. They are bundled because the grid layout makes the missing covers far more visually obvious, and the user surfaced both in the same observation.

## Goals

- Library renders as a 2-column grid of book cover cards matching the electron app's layout.
- PDF books show a real cover (first page rasterized to JPEG) instead of a letter-tile.
- E2E test coverage proves both visually (screenshot) and by assertion.

## Non-Goals

- Electron changes (already has grid + PDF covers).
- AZW3 cover extraction improvements.
- Any new cover-retry or regeneration UI beyond the existing long-press retry.
- DJVU cover extraction.
- Responsive column counts on tablet — fixed at 2 for now.

## Current State

- `apps/mobile/app/(tabs)/index.tsx` — `FlatList` of `BookRow`, plus a "Reading Now" card above for the last-read book.
- `apps/mobile/components/BookRow.tsx` — horizontal row: `BookCover size="sm"` + title/author column.
- `apps/mobile/components/ui/BookCover.tsx` — `expo-image` renderer with letter-tile fallback when `uri` is null or load fails. Sizes are `sm | md | lg`.
- `apps/mobile/lib/book-import/adapters.ts` (`createMobileCoverPort`) — extraction pipeline. Branches on format; rejects anything that isn't `epub | mobi | azw3` with `kind: "format-unsupported"`.
- `packages/shared/src/formats/epub-cover.ts`, `packages/shared/src/formats/mobi.ts` — cross-platform extractors returning `{ mimeType, data: Uint8Array }`.
- `apps/mobile/e2e/library.test.ts` — already seeds a PDF fixture and asserts `library-book-row-e2e-fixture-book-pdf` is visible. No grid-layout or cover-image assertion exists yet.
- Electron parity reference: `apps/rishi-electron/src/renderer/src/components/FileComponent.tsx` uses CSS grid `repeat(auto-fill, minmax(150px, 1fr))` with `aspect-[5/7]` covers + title/author below. PDF cover is extracted **at view time** from the rendered pdfjs canvas (`updateStoredCoverImage.tsx`).

## Design

### 1. Library Grid Layout

**File:** `apps/mobile/app/(tabs)/index.tsx`

- Replace the vertical `FlatList` of `BookRow` with a 2-column `FlatList` (`numColumns={2}`) of a new `BookGridCard`.
- Remove the "Reading Now" prominent card. The last-read book appears in the grid like any other (decision: confirmed with user — closest to Figma).
- Header (search bar, sync indicator, `+` import button) stays.
- `keyExtractor`, search filter, and import flow are untouched.

**New file:** `apps/mobile/components/BookGridCard.tsx`

- Receives the same `book`, `onPress`, `onDelete`, `onCoverRetry` props as `BookRow`.
- Layout: vertical card.
  - `BookCover` at 5:7 aspect ratio, full card width.
  - Title (2 lines max, ellipsized) below the cover.
  - Author (1 line, ellipsized, muted) below the title.
- Long-press retries cover extraction when `book.coverExtractionFailed` is true (same behavior as `BookRow`).
- TestIDs: `library-book-grid-card-${book.id}` for the pressable, `book-grid-card-cover-${book.id}` for the cover, plus a stable testID for the fixture (matching `fixtureBookRowTestID` semantics) so e2e helpers keep working.
- Delete: `BookRow` currently shows an inline trash icon. Port that to the grid card as a small trash button overlaid on the bottom-right corner of the cover, calling the same `onDelete(book)` handler. Long-press is reserved for cover-retry, matching current `BookRow` behavior.

**`BookCover` size token:**

- Add a `"grid"` size that lays out as `width: 100%` of parent and uses `aspectRatio: 5/7`. The existing `sm | md | lg` numeric sizes don't fit a flex-grid cell.
- Keep `sm | md | lg` unchanged so other call sites are unaffected.

**Spacing:**

- Grid gap: use theme `spacing.md` between columns and rows (no third-party gap polyfill — this Expo SDK supports RN `columnGap`/`rowGap`).
- Horizontal padding: existing screen padding stays.

**Empty state:**

- `library-empty-state` testID and copy unchanged.

### 2. PDF Cover Extraction

**Dependency:** `react-native-pdf-thumbnail` (page-0-only extraction; cheaper than `expo-pdf-to-image` which renders all pages).

- Install in `apps/mobile`.
- Autolinks under Expo prebuild — no config plugin needed.
- Requires dev client rebuild; document this in the spec's Rollout section so the e2e CI image is rebuilt before tests run.

**File:** `apps/mobile/lib/book-import/adapters.ts`

- In `createMobileCoverPort.extractAndStore`, allow `format === "pdf"` to pass the gate.
- Add a `pdf` branch parallel to the existing `epub`/`mobi` branches:
  - Call `PdfThumbnail.generate(bookPath, 0)`; returns `{ uri, width, height }` pointing at a temp JPEG in cache.
  - Read the temp JPEG with `FileSystem.readAsStringAsync(uri, { encoding: 'base64' })` → decode to `Uint8Array`, producing the same `{ mimeType: "image/jpeg", data }` shape that EPUB/MOBI extractors return.
  - Hand the bytes to the existing `writeCoverFile` + `updateBookCover` path, unchanged.
  - Best-effort cleanup of the temp JPEG after read (don't block on failure).
  - On any failure (rasterize error, read error), persist `COVER_EXTRACTION_FAILED_SENTINEL` and report via the existing `reportFailure({ kind: "rasterize-error" | "read-error", format: "pdf", cause })`. Reuse `kind: "read-error"` for the temp-file read step.
- No `packages/shared` changes — PDF rasterization is platform-native.

**Why not a shared extractor:** PDF rasterization on web/electron uses pdfjs in a DOM canvas; on iOS/Android it uses platform PDFKit/PdfRenderer. The signatures don't unify cleanly. The `CoverPort` is the existing seam for exactly this asymmetry.

### 3. Test Strategy (TDD, per repo convention)

**Unit tests** — new file `apps/mobile/lib/book-import/__tests__/cover-port-pdf.test.ts`:

- Happy path: `extractAndStore({ format: "pdf", bookPath, bookId })` calls `PdfThumbnail.generate(bookPath, 0)`, reads the resulting JPEG bytes, writes to covers dir, and calls `updateBookCover(bookId, path)`. Mocks the native module and `FileSystem`.
- Failure: `PdfThumbnail.generate` rejects → `updateBookCover(bookId, COVER_EXTRACTION_FAILED_SENTINEL)` is called and `reportFailure` fires with `kind: "rasterize-error"`.
- Failure: rasterize succeeds, but reading the JPEG bytes throws → same sentinel behavior, `kind: "read-error"`.

**Component tests** — `apps/mobile/components/__tests__/BookGridCard.test.tsx`:

- Renders cover when `coverPath` is set.
- Renders fallback (letter-tile) when `coverPath` is null and `coverExtractionFailed` is false.
- Renders fallback when `coverExtractionFailed` is true; long-press fires `onCoverRetry`.
- Tap fires `onPress`.

**E2E** — extend `apps/mobile/e2e/library.test.ts`:

- After importing the PDF fixture, assert `book-grid-card-cover-…` is visible (not the fallback letter-tile).
- Use Detox's screenshot API (`device.takeScreenshot("library-pdf-imported")`) and store under `apps/mobile/e2e/screenshots/` so the user can verify the grid visually — this is the user's explicit ask ("Use the e2e tests to take screenshots in order to see what is created").
- The existing `library-book-row-*` testID will rename to `library-book-grid-card-*`. Update `apps/mobile/e2e/helpers/seed-book.ts` (or wherever `fixtureBookRowTestID` is defined) accordingly. Old testIDs are not preserved — the row layout is going away.

### 4. Migration / Backfill

Books imported before this change have `coverPath: null` for PDFs. They will continue to show the letter-tile fallback unless re-extracted. Two options:

- **Implicit retry on long-press** — already works; users can manually retry.
- **One-time backfill** — on app startup, find PDFs with `coverPath: null` and `coverExtractionFailed: false`, and run extraction in the background.

Recommendation: rely on long-press retry. Backfill adds startup work for an edge case (pre-existing PDFs without covers). Punt unless the user pushes back.

## Rollout

1. Land the layout-only change first behind no flag — it's a pure UI swap.
2. Land the PDF extraction in a follow-up commit so the dev-client rebuild requirement is isolated and the diff is reviewable.
3. After install of `react-native-pdf-thumbnail`, run `npx expo prebuild` and rebuild the dev client. CI must rebuild before e2e runs (existing build step should handle this once `package.json` changes).

## Risks

- **`react-native-pdf-thumbnail` is last-released 2023.** Mature but unmaintained. If autolinking breaks under a future Expo SDK, swap to `expo-pdf-to-image` and accept the all-pages render cost. Document this in the package's import comment.
- **PDF rasterization on iOS may produce very large images for high-DPI scans.** Mitigate by capping output: the library returns a `uri` we can resize via `expo-image-manipulator` before persisting if image size becomes a problem. Out of scope for v1; revisit if profiling shows it.
- **Grid `numColumns` with variable header.** `FlatList` requires `numColumns` to be constant. The existing search bar header is rendered via `ListHeaderComponent`; that pattern is compatible with `numColumns={2}`.

## Open Questions

None at spec time.
