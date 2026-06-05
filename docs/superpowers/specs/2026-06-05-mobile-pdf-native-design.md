# Mobile PDF Reader — Native Architecture (Path E)

**Date:** 2026-06-05
**Scope:** `apps/mobile`
**Status:** Draft for review
**Author:** brainstorming pass with @matovu-farid
**Supersedes parts of:** `2026-06-05-mobile-import-polish-design.md` (the PDF-crispness stream there is abandoned in favor of this work)

## Goal

Replace the current pdfjs-in-WebView PDF reader with a native rendering
stack: `react-native-pdf` for the page surface (PDFKit on iOS, Pdfium on
Android), a new first-party Expo module `rishi-pdf-extractor` for
one-time text + word-rect extraction at import time, and SQLite as the
durable text cache that every reader feature (TTS, highlights, search,
TOC) reads from.

Both platforms ship together. Pinch-zoom is supported in v1.
Trunk-based development on `main` — small atomic commits, no PR
ceremony, each commit leaves the build green.

## Non-goals

- Touching EPUB rendering. EPUB uses `@epubjs-react-native/core`, has
  its own text-extraction path (the chunker), and shares only the
  highlights table and player machine — none of which this work
  changes contractually.
- Full-text search (FTS5). Search v1 uses `LIKE '%term%'` on
  `book_pages.text`. FTS5 is a follow-up.
- Native annotation rendering for highlights. v1 uses RN overlay views
  that listen to `onScaleChanged`. If overlay jitter during pinch-zoom
  is perceptible in QA, a follow-up moves highlights to `PDFAnnotation`
  (iOS) / Pdfium overlay (Android).
- Migrating desktop apps (Tauri / Electron) to the same architecture.
  Out of scope; could reuse the module later if extracted to a package.

## Background — current state (verified)

- **SQLite + Drizzle.** `apps/mobile/lib/db.ts` opens an `expo-sqlite`
  connection; schema is the shared `packages/shared/src/schema.ts`.
  Tables: `books`, `highlights`, `bookmarks`, `conversations`,
  `messages`, `sync_meta`, `sync_state`. Migrations use
  `PRAGMA user_version` via `runMigrations()` in `lib/db.ts:200-234`.
- **Highlights model is already PDF-space.** Stored as
  `cfiRange = "pdf:<json>"` where the JSON is
  `{ page: number, rects: [{x,y,w,h}] }` (PDF user-space, origin
  bottom-left), per `packages/shared/src/types/pdf-locator.ts:15-75`.
  No schema migration needed for highlights — only a new producer.
- **TTS consumer shape.**
  `apps/mobile/lib/pdf/read-aloud-from-selection.ts` calls
  `resolvePlayFromSelection(selectedText, paragraphs)` where
  `paragraphs: { index: string; text: string }[]`. Match is by prefix.
  As long as Path E produces the same shape from SQLite, TTS
  consumption is unchanged.
- **Current PDF text pipeline.** `components/pdf/webview-template.ts`
  loads pdfjs from a CDN, runs `pageDataToParagraphs` per page,
  bridges to RN via `components/pdf/pdf-webview-bridge.ts`.
- **TOC pipeline.** Currently from pdfjs in `buildOutline()`.
  `react-native-pdf` emits the same data structure via
  `onLoadComplete(_, _, _, tableContents)` for free — no native module
  work needed for TOC.
- **No existing custom native modules.** `app.json` declares
  `newArchEnabled: true` (Bridgeless). This module will be the first.
- **`react-native-pdf` v7.0.4 is installed** and used as a fallback
  today but is the new primary renderer. Confirmed props:
  `horizontal`, `enablePaging`, `enableDoubleTapZoom`, `page`,
  `onPageChanged`, `onScaleChanged`, `onLoadComplete`, `onChange`
  (iOS emits `textSelected|<string>` here when `enableTextSelection`
  is on). No text extraction APIs.
- **pnpm isolated linker quirk.** Per existing memory
  `project_mobile_pnpm_expo_modules.md`, transitive Expo modules can
  be hidden from CocoaPods. New local Expo modules must be declared in
  `app.json` plugins (or `expo-module.config.json`) to autolink
  reliably.

## Architecture

```
React Native (Expo, Bridgeless)
        │
        ▼
PdfNativeReader.tsx ───► <Pdf>  (react-native-pdf)
        │                  │
        │                  ├─ PDFKit (iOS)
        │                  └─ Pdfium (Android)
        │
        ├─► Highlight overlay layer (RN <View>s, tracks onScaleChanged)
        │
        ├─► Selection bridge
        │     iOS:     react-native-pdf onChange("textSelected|...")
        │     Android: gesture overlay (long-press + pan) hit-tests
        │              against bookWords for current page
        │
        ▼
SQLite (Drizzle)
        bookPages, bookWords, bookParagraphs, books.extractionStatus
        ▲
        │
Extraction job runner (JS) ──► rishi-pdf-extractor (Expo Module)
                                    │
                                    ├─ iOS Swift   → PDFKit
                                    └─ Android Kotlin → Pdfium
```

## Component 1 — Expo Module `rishi-pdf-extractor`

**Location:** `apps/mobile/modules/rishi-pdf-extractor/`

**Form:** Local Expo Module (Expo Modules Kit). Swift + Kotlin
`ModuleDefinition` DSL. Autolinks via `app.json` plugins.

### JS-facing API

```ts
import { extractPages, extractPage } from 'rishi-pdf-extractor';

type WordRect = {
  idx: number;     // monotonic per page
  text: string;
  x: number; y: number; w: number; h: number;  // PDF user-space points
};

type Paragraph = {
  index: string;   // matches existing TTS shape: `${pageNumber*10000 + i}`
  text: string;
};

type PageData = {
  pageNumber: number;
  widthPts: number;
  heightPts: number;
  paragraphs: Paragraph[];
  words: WordRect[];
};

extractPages(
  path: string,
  options: { pageNumbers: number[] }
): Promise<PageData[]>;

extractPage(path: string, pageNumber: number): Promise<PageData>;

getPageCount(path: string): Promise<number>;
```

Extraction runs on a native background queue/dispatcher. The JS layer
chunks the page list (default 25 pages per call) for memory safety on
low-end Android.

### iOS implementation (Swift)

- Uses `PDFKit` (system framework, no extra dep).
- `PDFDocument(url:)` → `document.page(at: i)`.
- Text: `page.string` for the raw string; paragraph segmentation is
  computed on the native side using the same vertical-gap heuristic as
  the current `pageDataToParagraphs` (5-line break or vertical gap >
  median line height × 1.5).
- Words: walk `page.numberOfCharacters` calling
  `page.characterBounds(at: i)` and `page.character(at: i)`; group
  consecutive non-whitespace characters into words; emit
  `(text, x, y, w, h)` in PDF user-space.
- Page size: `page.bounds(for: .mediaBox)` → width/height in points.

### Android implementation (Kotlin)

- Adds explicit dependency:
  `com.github.barteksc:pdfium-android:1.9.0`
  (same lib `react-native-pdf` transitively pulls; lock via
  `resolutionStrategy { force ... }` in module Gradle to prevent
  version drift).
- `PdfiumCore(context).newDocument(parcelFileDescriptor)` → page.
- Per page: `FPDFText_LoadPage`, then for `i in 0 until charCount`:
  `FPDFText_GetUnicode(textPage, i)` + `FPDFText_GetCharBox(...)`.
- Word grouping mirrors iOS — consecutive non-whitespace.
- Paragraph segmentation mirrors iOS heuristic.

### Cross-platform invariants

- Coordinate system is PDF user-space (origin bottom-left, points).
  Drizzle stores these as `REAL`.
- Paragraph IDs are deterministic: `pageNumber * 10000 + indexOnPage`
  (matches the existing pdfjs shape; the JS TTS resolver works
  unchanged).
- Word IDs (`idx`) are monotonic per page.

### Tests

- Pure-JS unit tests for the runner / chunker (mocked native module).
- Native-side: small Swift unit tests for paragraph segmentation
  against fixture text; same in Kotlin.
- Integration test (jest + module mocked) verifying that calling
  `extractPages` writes correct rows to SQLite.

## Component 2 — SQLite schema additions

Drizzle migration in `packages/shared/src/schema.ts`. New `user_version`
bump in `lib/db.ts`'s migration runner.

```ts
// New columns on `books`:
extractionStatus:  text(),        // 'pending' | 'extracting' | 'extracted' | 'error'
extractedPages:    integer(),
totalPages:        integer(),
extractionError:   text(),        // null unless status='error'

// New tables:
bookPages: {
  bookId:     text(),
  pageNumber: integer(),
  text:       text(),
  widthPts:   real(),
  heightPts:  real(),
  indexedAt:  integer(),
  PRIMARY KEY (bookId, pageNumber),
}

bookWords: {
  bookId:     text(),
  pageNumber: integer(),
  idx:        integer(),
  text:       text(),
  x: real(), y: real(), w: real(), h: real(),
  PRIMARY KEY (bookId, pageNumber, idx),
}

bookParagraphs: {
  bookId:     text(),
  pageNumber: integer(),
  paragraphIndex: text(),       // "${pageNumber*10000+i}"
  text:       text(),
  PRIMARY KEY (bookId, paragraphIndex),
}

// Indexes:
CREATE INDEX idx_bookPages_book        ON book_pages(bookId);
CREATE INDEX idx_bookWords_book_page   ON book_words(bookId, pageNumber);
CREATE INDEX idx_bookParagraphs_book   ON book_paragraphs(bookId);
```

`bookParagraphs` is denormalized from `bookPages.text` for two reasons:
(1) it matches the existing TTS resolver's data shape with no
adapter, (2) paragraph segmentation is non-trivial and we don't want
to redo it at query time.

## Component 3 — Extraction job runner

**File:** `apps/mobile/lib/pdf/extraction-runner.ts`

- Single-process in-memory FIFO queue.
- Worker dequeues one book at a time. Sets
  `books.extractionStatus = 'extracting'`.
- Reads `books.filePath` → calls `getPageCount` → updates
  `books.totalPages`.
- Chunks pages into groups of N (configurable, default 25). For each
  chunk:
  1. Call `extractPages(path, { pageNumbers })`.
  2. In a single SQLite transaction, insert `bookPages`, `bookWords`,
     `bookParagraphs` rows for the chunk, then bump
     `books.extractedPages`.
  3. Yield to the event loop before the next chunk so the UI thread
     can paint.
- On finish: `books.extractionStatus = 'extracted'`.
- On error: `books.extractionStatus = 'error'`,
  `books.extractionError = <message>`.

**Resume on app launch.** On boot, the runner queries
`SELECT id FROM books WHERE extractionStatus IN ('pending','extracting')`
and re-enqueues. Partial progress (`extractedPages`) means we resume
from where we left off — chunks that already inserted rows just
re-insert with `INSERT OR REPLACE`.

**Backfill of existing books.** Same boot-time scan finds rows with
`extractionStatus IS NULL` (existing books before the migration) and
marks them `pending`.

**Concurrency cap.** One book at a time globally. No per-book
parallelism in v1 (avoids OOM on big PDFs).

## Component 4 — Reader UI (`PdfNativeReader.tsx`)

**Replaces:** `components/pdf/PdfWebReader.tsx`.

### Rendering

```tsx
<Pdf
  source={{ uri: book.filePath }}
  horizontal
  enablePaging
  enableDoubleTapZoom
  page={currentPage}
  onPageChanged={(page, numPages) => setCurrentPage(page)}
  onScaleChanged={(scale) => setScale(scale)}
  onLoadComplete={(numPages, _path, _size, tableContents) => {
    setTotalPages(numPages);
    setOutline(tableContents);
  }}
  onChange={handleNativeEvent}   // iOS textSelected
  enableTextSelection            // iOS only; no-op on Android
/>
```

### TOC

Drives off `tableContents` from `onLoadComplete` directly. Stored in
`usePdfStore` (existing). The old `buildOutline` path is deleted.

### Highlights overlay

Per visible page, an absolutely-positioned `<View>` per highlight rect.
Coords transformed from PDF user-space to screen pixels using:

```
viewport_screen_width  = measured_view_width
pdf_to_screen_x = (pdf_x / page_widthPts)  * viewport_screen_width  * scale
pdf_to_screen_y = (page_heightPts - pdf_y - pdf_h) / page_heightPts
                                  * viewport_screen_height * scale
```

(Y flips because PDF origin is bottom-left, screen origin is top-left.)

Re-renders on `onScaleChanged` and `onPageChanged`. Color comes from
`highlights.color`; tap opens the existing highlight detail sheet
(`onPress` triggers the same handler as before).

### Text selection → TTS

**iOS:** `<Pdf>` emits `onChange` with payload
`"textSelected|<selected string>"`. We parse and pass the string into
the existing `resolvePlayFromSelection(selectedText, paragraphs)`
where `paragraphs` is `await db.select().from(bookParagraphs).where(eq(bookId, book.id) and eq(pageNumber, currentPage))`.

**Android:** A gesture overlay (`react-native-gesture-handler`
`LongPressGestureHandler` + `PanGestureHandler`) sits over the `<Pdf>`
view but only consumes events on long-press. On long-press start:
- Convert touch screen coords → PDF user-space (inverse of the
  highlight transform above).
- Hit-test against `bookWords` for `currentPage`. Find the word whose
  rect contains the point.
- Show a tinted selection rect over that word.
- Pan extends the selection word-by-word.
- On release, assemble the selected text from `bookWords[].text` in
  order, hand to the same `resolvePlayFromSelection` resolver.

The TTS player machine is unchanged — same `PLAY_FROM` dispatch.

### Partial-state UI

If `bookPages` for the current page is missing
(`extractionStatus !== 'extracted'`), the reader still renders pixels
normally (rendering doesn't need extraction). The bottom-bar TTS and
highlight controls show as disabled with a small "Indexing N / M
pages…" pill in the reader chrome. As `books.extractedPages` advances,
controls light up automatically. The runner emits an in-process event
(`extractionProgress { bookId, extractedPages, totalPages, status }`)
via a `mitt` / DeviceEventEmitter-style bus that the reader subscribes
to; this avoids polling and keeps the SQLite write path uncoupled from
React render. (Drizzle has no live-query API on Expo SQLite; pattern
chosen for parity with the existing sync notification bus in
`apps/mobile/lib/sync/*`.)

### Page indicator

Small "47 / 312" indicator in the reader chrome. Tap-to-jump via the
TOC drawer (existing UI; no changes).

### What stays the same

- The reader screen route (`app/reader/pdf/[id].tsx`) — only swaps the
  reader component import.
- Player machine, MiniPlayer, all UI chrome.
- Highlight CRUD APIs.
- The `resolvePlayFromSelection` resolver — only its `paragraphs`
  source changes.

## Component 5 — Cleanup

Deleted in the last commit of the sequence:

- `components/pdf/PdfWebReader.tsx`
- `components/pdf/webview-template.ts`
- `components/pdf/pdf-webview-bridge.ts`
- The CDN-loaded `pdfjs-dist` reference (it's in
  `webview-template.ts`; no package.json entry).
- Any unused fallback config that pointed at `react-native-pdf` as a
  fallback only.

## Commit sequence

Trunk-based on `main`. Each commit leaves the app installable and the
existing test suite passing.

1. **Drizzle migration**: add `extractionStatus`,
   `extractedPages`, `totalPages`, `extractionError` columns on
   `books`; add `bookPages`, `bookWords`, `bookParagraphs` tables;
   bump `user_version`. Migration is idempotent and additive (no
   destructive changes).
2. **Expo module skeleton — iOS hello-world**: `apps/mobile/modules/rishi-pdf-extractor/` with `expo-module.config.json`, Swift
   `RishiPdfExtractorModule.swift` returning a string, `app.json`
   plugins entry, Podfile autolink confirmation.
3. **Expo module skeleton — Android hello-world**: Kotlin
   `RishiPdfExtractorModule.kt` with `ModuleDefinition`, Gradle deps
   (including explicit `pdfium-android:1.9.0` lock).
4. **iOS `getPageCount` + `extractPage` (text + paragraphs only,
   no word rects yet)**.
5. **Android `getPageCount` + `extractPage` (text + paragraphs only)**.
6. **iOS word rects** via `characterBounds`.
7. **Android word rects** via `FPDFText_GetCharBox`.
8. **JS runner**: `extraction-runner.ts` with queue, chunking, partial
   commits, resume-on-boot. Unit tests against a mocked native module.
9. **Wire runner into `lib/file-import.ts`** so new imports
   immediately enqueue extraction in the background. No UI change yet.
10. **Backfill existing books on boot**: existing books with
    `extractionStatus IS NULL` get enqueued.
11. **`PdfNativeReader.tsx` v0**: renders `<Pdf>` with paging + TOC
    from `onLoadComplete`. No highlights, no TTS-from-selection yet.
    Behind no flag — placed at a new component path; the route still
    uses `PdfWebReader`.
12. **Highlight overlay**: render highlights from `highlights` table
    in `PdfNativeReader`. Verify visually against a fixture book.
13. **iOS text selection → TTS**: subscribe `onChange`, route through
    `resolvePlayFromSelection` against `bookParagraphs`.
14. **Android gesture-based selection**: long-press + pan overlay,
    word hit-test, same resolver.
15. **Route swap**: `app/reader/pdf/[id].tsx` now imports
    `PdfNativeReader`. Existing tests updated.
16. **Cleanup**: delete `PdfWebReader.tsx`, `webview-template.ts`,
    `pdf-webview-bridge.ts`.

Each commit ships a focused diff. Commit 11 onward requires a fresh
`eas build --platform ios --profile development --local` and the
equivalent Android dev client because new native code lands in commits
2-7.

## Tests

Per repo TDD convention, each commit lands with failing tests written
first.

- **Native module**: small native unit tests (Swift `XCTest`, Kotlin
  `junit`) for paragraph segmentation and word grouping against fixture
  PDFs in `apps/mobile/modules/rishi-pdf-extractor/tests/fixtures/`.
- **Runner**: jest unit tests with the native module mocked — queue
  ordering, chunk commit transactionality, resume-on-boot.
- **Reader integration**: jest tests on `PdfNativeReader` rendering
  with seeded SQLite — verifies highlight overlays render at correct
  positions for known fixture data.
- **TTS resolver**: existing tests in
  `__tests__/pdf/read-aloud-from-selection.test.ts` adapted to source
  paragraphs from SQLite instead of the webview message.
- **Maestro**: extend `08-pdf-reader.yaml` to assert reader opens,
  paragraph TTS works, highlights render after creation. Add an
  "indexing partial state" flow that imports a fixture, opens the
  reader before extraction finishes, and asserts the "Indexing…" pill
  appears.

## Risks

- **pnpm isolated linker hides the new local Expo module from
  CocoaPods.** Mitigation: declare the module in `app.json` plugins
  array; verify Podfile autolink via `npx expo prebuild` early. Per
  `project_mobile_pnpm_expo_modules.md` we may also need to add
  `expo-modules-core` to direct dependencies of `apps/mobile`.
- **Android `pdfium-android` version drift.** `react-native-pdf` pulls
  it transitively. Lock via `resolutionStrategy.force` in the Expo
  module's `android/build.gradle`.
- **Highlight overlay jitter during pinch-zoom.** `onScaleChanged`
  fires at React render cadence, not animation cadence. If
  perceptible, follow-up moves highlights to native `PDFAnnotation`
  (iOS) / Pdfium overlay (Android).
- **Extraction OOM on huge PDFs on low-end Android.** Mitigation:
  chunk size is tunable, default 25 pages; can drop to 5-10 for
  low-RAM devices. Future improvement: native-side streaming with
  page-by-page commits.
- **Paragraph segmentation divergence between iOS and Android.** Same
  heuristic written twice. Mitigation: shared fixture-based golden
  tests in both native test suites with identical expected outputs.
- **Android selection overlay accuracy under pinch-zoom.** The overlay
  must invert the same transform the highlight overlay uses; bugs
  produce miss-hits. Mitigation: factor the transform math into a
  pure function with unit tests.

## Open follow-ups (post-v1)

- FTS5 full-text search on `bookPages.text`.
- Native annotation rendering for highlights (eliminates overlay
  jitter).
- Cover extraction migration: today's `react-native-pdf-thumbnail`
  could be replaced by adding `getPageThumbnail(path, page)` to the
  same Expo module. Removes one third-party native dep.
- Reuse `rishi-pdf-extractor` from desktop (Tauri/Electron) by
  extracting it to its own package.
