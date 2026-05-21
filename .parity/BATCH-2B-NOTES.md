# BATCH 2B Notes — Book Import Parity + EPUB Cover Extraction (G26 + G32)

Date: 2026-05-21
Branch: main
Scope: Bring mobile book import to parity with electron and extract EPUB
cover images on import.

## What landed

1. **`@rishi/shared/formats/epub-cover`** — `extractEpubCover(Uint8Array)`
   ported from electron's `ipc/formats.ts`. Three cover-resolution
   branches (EPUB2 meta-cover, EPUB3 properties=cover-image, id-contains-
   "cover" heuristic), each tolerant to attribute order. Returns
   `{ mimeType, data } | null` so callers can fall back to a placeholder.
   Uses Uint8Array only — no Node Buffer — so it runs on RN. 13 tests
   including a real-EPUB end-to-end smoke from
   `packages/shared/src/formats/__fixtures__/test-book.epub` (copied
   from electron's e2e fixtures).

2. **`@rishi/shared/book-import`** — port-injected book-import service
   ported from `apps/rishi-electron/src/renderer/src/services/book-import/`.

   Differences vs electron:

   - **BookId is generic.** Electron uses numeric D1 ids; mobile uses
     UUID strings. The service threads `BookId` through ports, events,
     and `ImportResult`.
   - **Scanner port dropped.** Mobile has no folder-scan UX; electron's
     `scanner-adapter.ts` stays in the renderer where it was.
   - **CoverPort added.** Mobile extracts the cover at import time and
     stores it on disk; electron stores cover bytes inline on the row
     and skips this port.
   - **EmbedPort.generateChunks added.** Falls back to building chunks
     from the source file when neither caller nor DB has them — the
     path mobile takes during import.

   Tests: 64 new tests across `dispatch`, `emitter`, `importer`,
   `indexer`, `service` mirroring the electron suite + mobile-specific
   assertions (string ids, cover port, generateChunks fallback).

3. **`apps/mobile/lib/book-import/`** — adapters wiring the shared
   service to mobile's Drizzle DB, expo-file-system, R2 upload,
   on-device embedder + server fallback, and EPUB cover extractor.

4. **`apps/mobile/lib/file-import.ts`** — rewritten. Each public import
   function (`importEpubFile`, `importPdfFile`, `importMobiFile`,
   `importDjvuFile`, `importBookFromUrl`) now:
   1. Picks (or downloads) the source file.
   2. Mints a UUID.
   3. Calls `createMobileBookImportService({ bookId, format, title })`.
   4. Runs `service.importFromPath(sourceUri)`.
   5. Fires `service.indexBook(bookId, undefined, bookPath, format)` in
      the background (fire-and-forget — never throws into the picker).

5. **`Book.format`** widened to include `azw3` as a first-class variant.
   AZW3 still maps to the `mobi` R2 bucket (in `UploadPort` +
   `downloadBookFile`), but the user-visible row format is preserved so
   the UI can show the correct badge.

6. **Cover display** — Two existing places already render
   `book.coverPath` via `<Image source={{ uri }} />` (BookRow.tsx + the
   "Reading Now" card in `app/(tabs)/index.tsx`). The new import
   pipeline populates `coverPath` for EPUBs; the renderer needs no
   changes.

## Decisions

### Mobile vector storage stays "chunks + vectors together"

Electron's shared indexer assumes a two-step write: `savePageDataMany`
(chunks) and `saveVectors` (vectors). Mobile uses a `sqlite-vec` virtual
table where `insertChunkWithVector` writes both rows atomically. To
keep the shared service portable without rewriting either backend, the
mobile `DbPort.savePageDataMany` + `DbPort.saveVectors` are **no-ops**;
the actual writes happen inside `EmbedPort.generateChunks` via the same
`insertChunkWithVector` calls the legacy `lib/rag/pipeline.embedBook`
used. The shared service still calls those methods (contract) — they
just have nothing left to do.

### Mobile chunk IDs are deterministic, electron's are positional

This is the same tension flagged in BATCH-2A-NOTES.md and **not resolved
here**. Mobile's chunk IDs come from `stringToNumberID(bookId + '|' +
chunkText)`; electron's PDF pipeline uses
`pageNumber * 1e6 + bookId * 1e4 + index`. The two schemes don't
collide because they live in separate sqlite databases, but RAG dedup
across electron + mobile would need one to adopt the other. Tracked.

### Cover port runs BEFORE upload (post-save)

Both the cover extraction and R2 upload run after the `done` event as
fire-and-forget side-effects. Cover runs first so mobile's library grid
can render the cover even if the book file upload is still in flight.
Either step can fail without affecting the import result.

### EmbedPort.embed is a no-op on mobile, used only by electron

The shared indexer's regression-recovery path (chunks exist but vectors
don't) calls `embed.embed(batch)` directly — that's the electron path.
On mobile, `generateChunks` already writes both chunks AND vectors via
`insertChunkWithVector`, so the embed-then-saveVectors loop has
nothing to do. Returning `[]` from `embed.embed` makes the loop a no-op
without touching the contract.

### Mobile picker imports use a stub FormatsPort

Mobile's metadata extraction is intentionally minimal today (title from
filename, author='Unknown'). Rather than ship a parallel
metadata-extraction stack on RN, the mobile `FormatsPort` returns
`{ kind, cover: [], title: null }` and `buildBookInsertable` fills in
the real title from the source URI. This matches the existing UX
exactly while keeping the door open for future metadata extraction
(e.g. via the same WebView pattern used for PDF/DJVU text extraction).

## Out of scope / deferred

- **PDF first-page rasterization for cover.** Electron's PDF cover is
  blank too (`cover: []`). The follow-up would be to use
  `react-native-pdf-thumbnail` (already in deps) to rasterize page 1
  into a small JPEG and store it via the same CoverPort path. Not done
  here — keeping batch scope tight. Filed as follow-up.
- **DJVU cover.** Neither electron nor mobile extracts a DJVU cover.
  Would need to render the first page through the DJVU WebView
  extractor. Filed as follow-up.
- **MOBI/AZW3 cover.** PalmDOC has an embedded cover record (EXTH 201
  is the cover-offset index). The shared `parseMobiTextParagraphs`
  doesn't return image records today; adding a `parseMobiCover` to
  `@rishi/shared/formats/mobi` is the right surface, but again not in
  scope for 2B.
- **`pdfHashing` deduplication.** Electron deduplicates re-imports by
  fileHash; mobile's `uploadBookFile` already dedups on the R2 side but
  the local row is always re-inserted. A future port could check
  `fileHash` against existing rows in the importer's save stage.

## Packages installed

- `jszip@^3.10.1` — added as an optional peer + devDep to
  `packages/shared`. Already in `apps/mobile`'s direct deps via the
  existing EPUB chunker. No new mobile installs needed.

## Verification

- `pnpm -C packages/shared test`: 290 passed (was 191 entering batch;
  the 99 extra came from the parallel TTS batch that landed in
  `63c6731f`). My contribution: +77 (13 epub-cover + 64 book-import).
- `npx jest -C apps/mobile`: 201 passed / 2 failed (baseline 179/2).
  Same 2 pre-existing failures in `guardrails.test.ts` and
  `vector.test.ts`. My contribution: +7 in
  `__tests__/book-import/file-import.test.ts`. (Other +15 came from
  parallel TTS batch.)
- `npx tsc --noEmit -C apps/mobile`: 22 errors (baseline 22 — no new
  errors from this batch).
- `pnpm -C apps/rishi-electron typecheck`: clean (electron untouched).

## Commits

- `331a01ab` feat(shared): add extractEpubCover for cover-image extraction (G32)
- `351a8ad7` feat(shared): port book-import service to shared (G26)
- `5095d8d8` feat(mobile): wire book-import through @rishi/shared/book-import (G26)
