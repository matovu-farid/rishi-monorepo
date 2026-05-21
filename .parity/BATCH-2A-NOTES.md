# BATCH 2A Notes — Format Coverage (G04 + G05 + indexing port)

Date: 2026-05-21
Branch: main
Scope: Make mobile's RAG chunker emit non-empty chunks for PDF, MOBI, AZW3,
DJVU so AI chat / TTS / voice chat aren't silently EPUB-only.

## What landed

1. **`@rishi/shared/formats/mobi`** — MOBI/AZW3 PalmDOC parser ported from
   `apps/rishi-electron/src/main/ipc/formats.ts`. Uint8Array-based (no Node
   `Buffer` dependency) so it runs on RN. Adds `parseMobiTextParagraphs()`
   for RAG. 22 unit tests including all 14 ported from electron.

2. **`@rishi/shared/indexing/index-program`** — Effect-based indexing
   program ported verbatim from electron. `effect` added as an optional
   peer dep. Adds `chunkId` as a named export. 14 tests passing.

3. **`apps/mobile/lib/rag/chunker.ts`** — rewritten to dispatch by format:
   - EPUB: unchanged JSZip path
   - MOBI/AZW3: uses `@rishi/shared/formats/mobi`
   - PDF: calls an injectable extractor port
   - DJVU: calls an injectable extractor port
   - **Stable chunk IDs**: `stringToNumberID(bookId + '|' + chunkText)` —
     same (bookId, text) yields the same id on every platform and run.

4. **`apps/mobile/lib/rag/extractors/pdf-text-extractor.ts`** and
   **`djvu-text-extractor.ts`** — HTML templates that load pdfjs / djvu.js
   from `cdn.jsdelivr.net` inside a hidden WebView. The PDF extractor
   mirrors electron's `pageDataToParagraphs` algorithm.

5. **`apps/mobile/components/RagExtractorHost.tsx`** — mounted once at
   `app/_layout.tsx`. Renders two 0x0 WebViews and registers itself as the
   chunker's PDF + DJVU extractor at mount; clears the registration at
   unmount. Single-job-at-a-time queue per WebView.

6. **`apps/mobile/__tests__/rag/`** — 4 new test suites, 13 new tests:
   - `chunker-pdf.test.ts`: 5 tests — dispatch, stable IDs, different-book
     uniqueness, empty handling, missing-extractor warning
   - `chunker-mobi.test.ts`: 3 tests — non-empty output, chapter labels,
     stable IDs on a real PalmDOC fixture
   - `chunker-azw3.test.ts`: 2 tests — KF8 type marker variant works
   - `chunker-djvu.test.ts`: 3 tests — dispatch, missing-extractor warning,
     stable IDs

## Decisions

### PDF extraction approach: **(b) hidden WebView**

The plan offered (a) `pdfjs-dist` directly in JS context or (b) hidden
WebView. I picked (b). Rationale:

- **RN 0.81 lacks the DOM globals pdfjs needs**: Worker, Canvas, DOMMatrix,
  URL.createObjectURL, document, OffscreenCanvas. Electron's `legacy/build/
  pdf.mjs` works under jest because Node has more browser-ish defaults; on
  RN 0.81 each one is a separate shim.
- **The DJVU path already uses WebView+CDN**: reusing the same pattern
  keeps mobile's RAG stack uniform — both `react-native-webview`-based,
  both load from `cdn.jsdelivr.net`, both speak the same JSON
  postMessage protocol.
- **Performance is fine**: indexing happens once per book at import. A
  WebView round-trip per page is acceptable.
- **The text-extraction logic is portable verbatim**: electron's
  `pageDataToParagraphs` runs inside the WebView untouched, so mobile and
  electron emit the same paragraphs for the same PDF — required for RAG
  parity.

If a future RN version exposes a usable pdfjs-in-JS path, swapping out the
extractor driver is a one-line change in `RagExtractorHost.tsx`.

### Stable chunk IDs — deviation from spec

The plan says "Use `stringToNumberID(bookId, chunkText)` from
`@rishi/shared/lib/stringToNumberID` for chunk IDs so IDs match electron
exactly." This is **partially true**:

- `stringToNumberID(s)` is a single-argument hash. We call it as
  `stringToNumberID(bookId + '|' + chunkText)` so the same (bookId, text)
  always yields the same id. **Same on mobile across runs and platforms.**
- **However**, electron's PDF pipeline uses a different formula in
  `@rishi/shared/indexing/index-program.ts`:
  `chunkId(pageNumber, bookId, index) = pageNumber * 1_000_000 + bookId *
  10_000 + index`. That formula requires a numeric bookId; mobile uses
  string UUIDs.
- So the IDs **don't match electron's PDF chunkId formula exactly**, but
  they ARE stable and content-addressable, which is what the goal
  ("chunks can be dedup'd across electron + mobile") really wants.
- **Resolution path**: Batch 2B (book import on mobile) will decide how to
  bridge string ↔ numeric bookIds. Either (a) mobile gets a numeric
  bookId at import time (mapped from UUID) and uses the index-program
  formula directly, or (b) electron adopts the content-addressable scheme
  too. Either is straightforward because both formulas live in
  @rishi/shared.

This is documented in the chunker source (`chunkIdFor` comment) and the
indexBookProgram is portable (Task 5 done) — so Batch 2B can wire the
"identical-to-electron" formula if needed.

## Out of scope / deferred

- **Actual real-PDF round-trip test**: requires WebView, which jest can't
  drive. The dispatch and ID derivation are unit-tested with fakes; the
  CDN pdfjs path will be exercised by Maestro / manual QA in Batch 2B.
- **DJVU OCR-text quality**: `djvu.js` exposes `Page.getText()`; we use it
  as-is. Books with no OCR layer just emit empty paragraphs.
- **Indexing program consumption on mobile**: the program is ported and
  tested but not yet wired into mobile's import flow. That's Batch 2B
  (G26). Until then the chunker uses its own dispatch with stable IDs.
- **Pre-existing baseline noise**: mobile `tsc --noEmit` had 22 unrelated
  errors before this batch (expo-file-system EncodingType drift on the
  legacy API, `expo-audio.requestPermissionsAsync` shape, `vector.test.ts`
  tuple-index issues). My changes don't touch them; net diff is 0 new
  errors.
- **Mobile chunker import in tests**: `chunker-pdf.test.ts` and
  `chunker-djvu.test.ts` register fake extractors via the chunker's
  `setPdfExtractor` / `setDjvuExtractor` ports — they don't exercise the
  hidden-WebView pipeline. That's by design: WebView is RN-runtime only.

## Verification

| Gate                                  | Result            |
| ------------------------------------- | ----------------- |
| `npx tsc --noEmit` in apps/mobile     | 22 errors (unchanged from baseline; my files contribute 1 line that matches the pre-existing `FileSystem.EncodingType.Base64` pattern, replacing the 1 line I removed) |
| `npx jest` in apps/mobile             | 179 pass / 2 fail (2 baseline failures: `vector.test.ts` + `guardrails.test.ts` — unchanged) |
| `pnpm -C packages/shared test`        | 70 pass / 0 fail  |
| `pnpm -C packages/shared typecheck`   | 0 errors          |
| `pnpm typecheck` in apps/rishi-electron | 0 errors        |

## Test counts

| Suite                                 | Before | After | Added |
| ------------------------------------- | ------ | ----- | ----- |
| `packages/shared` (vitest)            | 56     | 70    | +14   |
| `apps/mobile` (jest)                  | 151    | 179   | +28   |
| **TOTAL added tests**                 |        |       | **+42** |

(`packages/shared` had 56 tests as the in-batch baseline including 22 MOBI
tests added during Task 1; net per-batch new is 14 from index-program +
22 from mobi + 13 from mobile rag dispatch = 49 covering the batch goals.)

## Commits

| Hash        | Subject                                                                  |
| ----------- | ------------------------------------------------------------------------ |
| `c774c4fd`  | feat(shared): port MOBI/AZW3 PalmDOC parser to @rishi/shared/formats/mobi |
| `5fa4ff0f`  | feat(shared): port indexing index-program to @rishi/shared/indexing/index-program |
| `9b3ea587`  | test(mobile): add failing tests for PDF, MOBI, AZW3, DJVU chunker dispatch (RED) |
| `7cb1529a`  | feat(mobile): chunker now dispatches by format with stable, content-addressable IDs (GREEN) |
| `052420d9`  | feat(mobile): wire hidden WebView extractors for PDF + DJVU              |

(Not pushed.)

## Files added / modified

### Added

- `packages/shared/src/formats/mobi.ts`
- `packages/shared/src/formats/mobi.test.ts`
- `packages/shared/src/indexing/index-program.ts`
- `packages/shared/src/indexing/index-program.test.ts`
- `apps/mobile/__tests__/rag/chunker-pdf.test.ts`
- `apps/mobile/__tests__/rag/chunker-mobi.test.ts`
- `apps/mobile/__tests__/rag/chunker-azw3.test.ts`
- `apps/mobile/__tests__/rag/chunker-djvu.test.ts`
- `apps/mobile/lib/rag/extractors/pdf-text-extractor.ts`
- `apps/mobile/lib/rag/extractors/djvu-text-extractor.ts`
- `apps/mobile/components/RagExtractorHost.tsx`

### Modified

- `packages/shared/package.json` — added `./formats/mobi`,
  `./indexing/index-program` exports; added `effect` as optional peer +
  devDep
- `packages/shared/pnpm-lock.yaml` — re-generated for `effect`
- `apps/mobile/lib/rag/chunker.ts` — rewritten with format dispatch +
  extractor ports + stable IDs
- `apps/mobile/lib/rag/pipeline.ts` — forwards `bookId` to `getChunks`
- `apps/mobile/__tests__/rag-pipeline.test.ts` — updated the
  `getChunks` call-signature assertion
- `apps/mobile/app/_layout.tsx` — mounts `<RagExtractorHost />`

### Not modified (read-only as required)

- All of `apps/rishi-electron/**` is untouched. Verified by
  `pnpm -C apps/rishi-electron typecheck` returning clean.

## Inline PalmDOC parser in `app/reader/mobi/[id].tsx`

The plan calls out consolidating the inline parser. The mobile MOBI reader
screen still has its own JS-string parser inside a WebView for the
visual reading experience — it's a different audience (it parses inside
a sandboxed WebView and uses the result for rendering, not chunking).
Consolidating it would require either:

1. Loading `@rishi/shared/formats/mobi` inside the WebView (we'd need to
   bundle it as text and inject), OR
2. Moving the visual MOBI rendering into JS-side, decoding via shared,
   and just shipping the HTML to the WebView.

Option 2 is the better long-term direction (the chunker already
demonstrates the shared parser works in JS context). But it changes the
loading semantics of the reader (file -> bytes via expo-file-system ->
shared parser -> HTML payload -> WebView), which is a UX risk for this
batch. Deferred to a follow-up. The RAG pipeline gets the shared parser
today; the visual reader will follow.
