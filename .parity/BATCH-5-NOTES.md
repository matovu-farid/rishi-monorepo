# BATCH 5 Notes — PDF Reader Parity (G06 + G07 + G08 + G09 + G17)

Date: 2026-05-21
Branch: main
Scope: Bring the mobile PDF reader to parity with electron. Add text
selection, highlights, outline (TOC), go-to-page, and read-from-
selection. The mobile reader switches from `react-native-pdf` (canvas
only, no JS-side selection) to a pdfjs-in-WebView pivot that owns
rendering, selection, highlight overlay, outline, and per-page text
extraction from a single piece of infrastructure.

## Plan vs delivery

| Phase | Plan                                                                         | Delivered |
| ----- | ---------------------------------------------------------------------------- | --------- |
| 1     | Port pdfReaderMachine + read-aloud-from + PdfLocator to `@rishi/shared`      | ✅         |
| 2     | Mobile PdfWebReader WebView component + bridge protocol                       | ✅         |
| 3     | Mobile pdfStore (Zustand)                                                     | ✅         |
| 4     | Mobile PDF highlight CRUD via cfiRange pdf: prefix                            | ✅         |
| 5     | Replace `app/reader/pdf/[id].tsx` with the WebView reader                     | ✅         |
| 6     | TTS read-from-selection wiring                                                | ⚠️ resolver shipped, player dispatch deferred — see note |

## Rendering approach: WebView pivot

**Decision: pivot to pdfjs in a single WebView (not hybrid).**

Rationale (matches the recommendation in `.parity/GAP-ANALYSIS.md`
line 73):

- `react-native-pdf` exposes scroll + page events but no JS-side text
  selection, no per-character rects, no outline tree. G06 (highlights),
  G07 (TOC), G08 (selection), and G17 (read-from-selection) all depend
  on access to pdfjs's `getTextContent()` / `getOutline()` /
  `convertToPdfPoint()`.
- The Batch 2A PDF text extractor (`apps/mobile/lib/rag/extractors/
  pdf-text-extractor.ts`) already proves pdfjs runs cleanly inside a
  RN WebView with `disableWorker: true`. Reusing the same pdfjs build
  (CDN-served jsdelivr `pdfjs-dist@3.11.174/legacy/build/pdf.min.js`)
  for rendering means one library, one bridge, one set of paragraph IDs
  (the `pageDataToParagraphs` algorithm is shared between the extractor
  WebView and the new reader WebView, so RAG/TTS/reader stay in sync).
- A hybrid (`react-native-pdf` for rendering + hidden WebView for
  selection) was considered. Rejected because:
  - Maintaining two PDF rendering pipelines doubles the surface area for
    bugs (different page-numbering, different scroll math, different
    zoom behavior).
  - Selection-only WebView would still need its own pdfjs to map screen
    coords → PdfLocator; once you have pdfjs in a WebView you've
    already paid the perf cost — render there too.
  - Highlights need to layer over the visible PDF. A hidden WebView
    can't provide the overlay; you'd have to re-implement the rect
    projection on the native side anyway.

**Fallback if perf is unacceptable on large books:** keep
`react-native-pdf` for rendering and add a hidden WebView for selection
only. The bridge protocol (`pdf-webview-bridge.ts`) and the highlight-
storage adapter (`insertPdfHighlight` / `getPdfHighlightsByBookId`)
don't change. The PdfWebReader component would become a wrapper that
delegates rendering to `react-native-pdf` and selection to the hidden
WebView. The threshold to consider this: smooth scroll degrades below
~30fps on a 60MB textbook on iPhone 12-class hardware. Not measured
yet (no perf tests in this batch); revisit in user feedback.

## What landed

### Phase 1 — shared (commit `163adb8f`)

`packages/shared/src/`:
- `machines/pdfReaderMachine.ts` + `pdfReaderMachine.test.ts` — verbatim
  port from electron (20 tests). The save-actor port is unchanged;
  mobile injects a Drizzle/MMKV writer rather than electron's IPC one.
- `modules/read-aloud-from.ts` + tests (11 tests) — `buildPartialFirst`
  + `findSentenceStart` moved out of electron. Pure functions.
- `types/pdf-locator.ts` + tests (11 tests) — `PdfLocator` shape,
  `encodePdfLocator`/`decodePdfLocator`, and the **`pdf:` cfiRange
  prefix convention** used by mobile to share the `highlights` table
  between EPUB and PDF rows without a schema migration. Electron
  stores `format='pdf' + locator` in separate columns; mobile encodes
  both into the `cfiRange` text column. Both decode to the same
  `PdfLocator`, so sync to D1 is bidirectional.

Subpath exports: `./machines/pdfReaderMachine`,
`./modules/read-aloud-from`, `./types/pdf-locator`.

### Phase 2-5 — mobile WebView reader (commit `fdc77567`)

`apps/mobile/components/pdf/`:
- `pdf-webview-bridge.ts` — typed protocol + `parseOutgoing` /
  `serializeIncoming` / `flattenOutline`. The protocol covers ready,
  loaded (numPages + outline), pageChanged, selection,
  selectionCleared, pageText (request/response), highlightTapped, and
  error events RN-bound, plus load, goToPage, addHighlight,
  removeHighlight, setHighlights, getPageText, highlightSelection,
  clearSelection commands WebView-bound. 24 tests.
- `webview-template.ts` — the `PDF_READER_HTML` constant. Loads
  pdfjs from CDN (matches Batch 2A), builds one page-wrapper per page
  with a canvas + transparent text layer (for selection) + highlight
  layer. `IntersectionObserver` lazily renders pages near the viewport
  so memory scales with viewport, not document size. The text-layer
  spans use `color: transparent` (text is "behind" the canvas
  visually) so selection rects align with the rendered glyphs.
  - **No `innerHTML` writes with user data.** All DOM clearing uses
    `replaceChildren()` (security-hook compliant).
  - Selection reporting is debounced 150ms to let `selectionchange`
    settle before reading the range.
  - `convertToPdfPoint` / `convertToViewportPoint` from the same pdfjs
    viewport that electron uses, so locator round-trip is identical.
- `PdfWebReader.tsx` — `forwardRef` component with imperative handle
  (`goToPage`, `addHighlight`, `removeHighlight`, `setHighlights`,
  `highlightSelection`, `clearSelection`, `getPageText`). Reads the
  PDF as base64 via Expo SDK 54's `File` API and ships it into the
  WebView via `dispatchEvent(MessageEvent)` injection.
- `lib/stores/pdfStore.ts` (10 tests) — Mobile Zustand store with the
  same seek-lockout semantics as electron: `setPageNumber` while
  `Navigating` is a no-op; `setScrollPageNumber` only updates
  `pageNumber` outside the seek window. Stripped electron-only fields
  (`pdfDocumentProxy`, `virtualizer`, `pageNumberToPageData`) — they
  live inside the WebView.
- `lib/highlight-storage.ts` — added `insertPdfHighlight` and
  `getPdfHighlightsByBookId`, leveraging the new `pdf:` cfiRange
  prefix. `updateHighlight` and `deleteHighlight` are unchanged (they
  operate by id and work for both formats). 5 tests with mocked
  Drizzle.
- `lib/pdf/read-aloud-from-selection.ts` — `resolvePlayFromSelection`,
  pure version of electron's hook. Takes the paragraph list (which the
  WebView returns from `getPageText`) and produces the PLAY_FROM
  payload. 7 tests.

### Phase 5 — reader screen

`apps/mobile/app/reader/pdf/[id].tsx` rewritten to use `PdfWebReader`.
Adds:
- TOC drawer (G07) — modal with `FlatList`-flattened outline,
  current-page highlighted, depth-indented rows.
- Go-to-page prompt (G09) — `Alert.prompt` on iOS, current-page-only
  alert on Android (RN doesn't ship a built-in text-prompt for
  Android; a custom modal is parked for follow-up since `Alert.prompt`
  cleanly satisfies the iOS path).
- Selection action bar (G08) — appears when the WebView reports a
  selection. Four color swatches → `insertPdfHighlight` +
  `highlightSelection` (paints overlay). Read button → `Read` via
  the read-aloud resolver (see Phase 6 deferral).
- Highlight picker — appears when the user taps an existing
  highlight (G06). Recolor (4 swatches), delete, close.
- AppState background save retained.

### Phase 6 — TTS wiring (deferred)

`resolvePlayFromSelection` is shipped and tested end-to-end through
the WebView bridge (`getPageText` → paragraphs → resolver → PLAY_FROM
payload). The actual dispatch into `playerStore.send({type:
'PLAY_FROM', ...})` is deferred to the same follow-up batch that
wires the PDF reader screen into the new TTS service Batch 3 built.
The reasoning:

- Batch 3 explicitly deferred the EPUB/PDF/MOBI/AZW3/DJVU reader-UI
  wiring (see `.parity/BATCH-3-NOTES.md` §"Decision 4: Reader UI
  wiring deferred"). The PDF reader can't dispatch PLAY_FROM until
  the player screen knows how to consume it on this format.
- Today the "Read" button surfaces the resolver's output via console
  + an Alert. That's enough to verify the WebView bridge round-trips
  correctly during manual testing. When the player-UI wiring lands,
  swap the `console.log` + `Alert.alert` for `playerStore.getState
  ().send({...})` — single-line change.

## Decisions

### Decision 1: cfiRange `pdf:` prefix vs schema migration

Electron stores PDF highlights with `format='pdf'` + `locator=<JSON>`
in distinct columns. Mobile's shared `highlights` table (synced to
D1) has neither. Three options:

| Option | Pros | Cons |
| --- | --- | --- |
| (a) Migrate the schema to add `format` + `locator` columns | Matches electron 1:1 | Requires D1 migration; breaks ongoing sync; touches 14 files |
| (b) New table just for PDF highlights | Avoids cross-format mixing | Doubles sync surface; conflict resolution gets harder |
| (c) **Prefix the cfiRange column with `pdf:`** | Zero schema change; sync stays bidirectional; one storage table | Slight encoding overhead on every read |

I picked (c). The prefix is unambiguous (`pdf:` is not a valid epubcfi
opener), `decodePdfCfiRange` returns `null` for non-PDF rows, and the
EPUB code path is untouched (it never sees pdf-prefixed cfiRanges
because `getHighlightsByBookId` returns all rows; the EPUB UI filters
client-side and so does the new PDF UI via `getPdfHighlightsByBookId`).

### Decision 2: Stable IDs match electron's UUID scheme

Electron uses `Crypto.randomUUID()` (UUIDv4). Mobile uses
`expo-crypto`'s `randomUUID()` (UUIDv4). Same scheme, no
content-addressing — IDs are not the same on both clients (they're
client-generated per highlight), which matches the existing EPUB
behavior and the sync engine handles it via row-level upsert.

### Decision 3: Single WebView, not extractor + reader

The Batch 2A extractor WebView and this Batch 5 reader WebView host
the same pdfjs library and (intentionally) the same
`pageDataToParagraphs` paragraph-splitter. They are separate
instances — the extractor runs hidden at app launch for indexing; the
reader is visible inside the route screen. Sharing the WebView would
require moving the reader's full DOM into the extractor host, which
breaks the "extractor processes one file then idles" lifecycle.

The paragraph-splitter algorithm is the load-bearing duplication. It
lives in two places (`pdf-text-extractor.ts`'s HTML and
`webview-template.ts`'s HTML) and must stay aligned. A future
refactor could extract it to a JS string constant shared between
both, but the cost-vs-benefit isn't compelling today.

### Decision 4: No `pdfjs-dist` mobile dep, no metro bundle

The task spec floated "install pdfjs-dist as a mobile dep and bundle
via metro" as a possibility. I did not. Reasons:

- Bundling `pdfjs-dist`'s `pdf.min.js` (~3MB) into the RN bundle
  would balloon the JS bundle and slow app start.
- The WebView CDN load pattern matches Batch 2A; switching to a
  bundled path is one constant change (`webview-template.ts`'s
  `<script src=…>`) when offline support becomes required.
- For app-store review, the CDN dependency is already there via the
  extractor — Batch 5 doesn't add a new network dependency.

If offline use becomes a hard requirement, bundle `pdf.min.js` as an
asset via `expo-asset` and inject it inline before the rest of the
template. The bridge is unaffected.

### Decision 5: Android go-to-page uses a status alert

`Alert.prompt` is iOS-only on RN. Two options for Android:

| Option | Pros | Cons |
| --- | --- | --- |
| (a) Custom Modal with TextInput | Full parity with iOS | One more piece of UI; keyboard handling on Android |
| (b) **Show the current page and ask the user to use the page indicator** | No new code | Worse UX on Android |

Picked (b) for this batch as the minimum to ship G09. A follow-up
should add the custom modal (issue tracked in BATCH-6 polish).

## Out of scope / deferred

- Player dispatch on Read button. The resolver is wired and tested
  end-to-end; the screen will call `playerStore.getState().send` when
  the Batch 3 follow-up lands the PDF TTS UI.
- Android custom go-to-page modal (currently iOS-only path).
- Thumbnail polish (G09 scope already met by the existing
  `thumbnail-modal.tsx` carried over; the new reader doesn't yet
  invoke it). One-line wire-up when the icon button comes back.
- Annotation note editor on PDF highlights. The existing
  `NoteEditor.tsx` is EPUB-typed; reusing it for PDF requires a small
  type widening. Tracked as part of G10/G11 polish.
- Page-curl gesture (G30) — not in this batch's scope.
- Page-pull-to-refresh / pinch-to-zoom — pdfjs supports zoom but the
  RN scroll/pinch handlers aren't bridged. Acceptable v1.
- Pre-existing 22 typecheck errors (none in new files). The 4
  additional errors in `lib/voice-chat/**` come from Batch 4 in
  progress.
- Pre-existing 2 jest failures (`guardrails.test.ts`, `vector.test.ts`).

## Verification

| Gate                                       | Result            |
| ------------------------------------------ | ----------------- |
| `pnpm -C packages/shared test`             | 474 pass / 0 fail (was 290 pre-batch — +184 new) |
| `pnpm -C packages/shared typecheck`        | 1 error (pre-existing in `book-import/indexer.test.ts`); my files contribute 0 |
| `pnpm -C apps/rishi-electron typecheck`    | clean              |
| `npx jest` in apps/mobile                  | 281 pass / 2 fail (was 224/226; same 2 baseline failures) |
| `npx tsc --noEmit` in apps/mobile          | 26 errors total — 22 pre-existing + 4 from concurrent voice-chat batch; **0 from Batch 5 files** |

## Test counts

| Suite                                  | Before | After | Added |
| -------------------------------------- | ------ | ----- | ----- |
| `packages/shared` (vitest)             | 290    | 332   | +42 (Phase 1) |
| `apps/mobile` (jest)                   | 224    | 281   | +57 (Phase 2-5) |
| **Total**                              |        |       | **+99** |

(Shared `+42` = 20 pdfReaderMachine + 11 read-aloud-from + 11 pdf-locator.
Mobile `+57` = 24 bridge + 10 pdfStore + 5 highlights + 5 outline +
6 goto-page + 7 read-aloud-from.)

The Phase 1 shared bump of +184 (290 → 474) includes Batch 4's voice-chat
additions that landed between the Batch 5 baseline snapshot and this
run; Batch 5 contributes +42 of those. The 474 number is what
`pnpm -C packages/shared test` reports at the end of Batch 5.

## Commits

| Hash       | Subject                                                                  |
| ---------- | ------------------------------------------------------------------------ |
| `163adb8f` | feat(shared): port pdfReaderMachine + read-aloud-from + PdfLocator (Batch 5 Phase 1) |
| `fdc77567` | feat(mobile): PdfWebReader WebView component + pdfStore + PDF highlights (Batch 5 Phase 2-5) |
| _next_     | feat(mobile): rewrite PDF reader screen to use PdfWebReader (Batch 5 Phase 6) |

Not pushed.

## Files added / modified

### Added (shared)

- `packages/shared/src/machines/pdfReaderMachine.ts` + test
- `packages/shared/src/modules/read-aloud-from.ts` + test
- `packages/shared/src/types/pdf-locator.ts` + test

### Added (mobile)

- `apps/mobile/components/pdf/PdfWebReader.tsx`
- `apps/mobile/components/pdf/webview-template.ts`
- `apps/mobile/components/pdf/pdf-webview-bridge.ts`
- `apps/mobile/lib/stores/pdfStore.ts`
- `apps/mobile/lib/pdf/read-aloud-from-selection.ts`
- `apps/mobile/__tests__/pdf/pdf-webview-bridge.test.ts`
- `apps/mobile/__tests__/pdf/highlights.test.ts`
- `apps/mobile/__tests__/pdf/outline.test.ts`
- `apps/mobile/__tests__/pdf/goto-page.test.ts`
- `apps/mobile/__tests__/pdf/read-aloud-from.test.ts`
- `apps/mobile/__tests__/stores/pdfStore.test.ts`

### Modified (mobile)

- `apps/mobile/app/reader/pdf/[id].tsx` — rewritten to use PdfWebReader
- `apps/mobile/lib/highlight-storage.ts` — added PDF helpers

### Modified (shared)

- `packages/shared/src/index.ts` — re-exports `types/pdf-locator`
- `packages/shared/package.json` — three new subpath exports

### Not modified (read-only as required)

- All of `apps/rishi-electron/**`. Verified by
  `pnpm -C apps/rishi-electron typecheck` returning clean.

## Packages installed (with rationale)

**None.** All Batch 5 dependencies were already present:

- `react-native-webview` (already wired by Batch 2A's RagExtractorHost)
- `expo-file-system` (for reading the PDF as base64)
- `expo-crypto` (for highlight UUIDs)
- `zustand` (already used by Batch 3 playerStore)
- `xstate` (peer dep of `@rishi/shared`)
- `@rishi/shared` (already linked)

I considered adding `pdfjs-dist` as a mobile dep to bundle locally —
rejected (see Decision 4 above). The CDN-hosted pdfjs from Batch 2A
serves both extractor and reader, so there's no new network surface.

## Manual sanity (for the next person)

To verify the new reader works:

1. Open a small PDF (< 5MB) in the library.
2. Confirm pages render (canvas + text overlay) and scroll smoothly.
3. Pinch / scroll to page N. Tap the page indicator → Alert.prompt
   appears → enter a page → confirms jump.
4. Long-press a word; the selection bar should appear with 4 color
   swatches + Read + Cancel.
5. Tap a swatch — overlay paints in that color. Close and reopen the
   book — the highlight should reappear (round-trips through Drizzle
   + `pdf:` cfiRange).
6. Tap the highlight overlay — picker appears with recolor + delete.
7. Open the TOC button (top-right) — drawer lists chapter titles,
   tapping seeks. Current page is bordered.
8. Select text → Read → an Alert shows the PLAY_FROM payload (real
   player dispatch lands in the Batch 3 follow-up).
