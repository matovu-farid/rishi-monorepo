# Batch 8 Notes — Final Wiring Pass

**Date:** 2026-05-21
**Scope:** Close the residual partials identified by `.parity/VERIFICATION.md`. No new primitives; pure wiring + small UX polish.

## Headline

| Bucket   | Before (VERIFICATION.md) | After Batch 8 |
| -------- | ------------------------ | ------------- |
| Closed   | 23                       | **29**        |
| Partial  | 7                        | 1 (G15)*      |
| Open     | 2 (P3 by design)         | 2 (unchanged) |
| **Total**| 32                       | 32            |

*G15 stays "partial" because the EPUB visual-cue path uses a text-based heuristic rather than a DOM-scanning postMessage bridge — see "G15 — design note" below.

P0: 5/5. P1: 14/14 (G14 closed for all 4 readers, G17 closed for EPUB, G18 already closed). P2: 8/8 except G10 surface polish (closed via undo snackbar), G09 (closed via thumbnail relink + Android modal), G17 (closed). P3 deferrals (G19, G22, G30, G31) unchanged.

## What landed

### G20 — page-capture refs (commit 51c90d83)

- New `hooks/usePageCaptureRef.ts`: registers a ref with the page-capture registry on mount, clears on unmount only if we still own the slot (out-of-order unmounts during screen transitions can't wipe the new screen's ref).
- Wired into all 4 reader screens (`app/reader/[id].tsx`, `pdf/[id].tsx`, `mobi/[id].tsx`, `djvu/[id].tsx`) — the ref is attached to each screen's top-level content view.
- Voice-chat `inspectCurrentPage` tool now returns real screenshots instead of the 1×1 placeholder.
- 4 jest tests (`__tests__/voice-chat/page-capture-refs.test.tsx`) cover mount/unmount/replacement.

### G14 — TTS chat-resume in MOBI + DJVU (same commit)

- Added `useTtsChatBridge(realtimeStatus)` to `app/reader/mobi/[id].tsx` and `app/reader/djvu/[id].tsx`. EPUB + PDF already had it.
- Source-level wiring assertions added to `__tests__/tts/chat-bridge.test.ts` — 4 tests verifying every reader file imports + invokes the bridge.

### G15 — TTS visual cue render + drive (commit 13e10c44)

- Mounted `<TTSVisualCue />` in all 4 reader screens.
- New `lib/tts/visual-cue-classify.ts`: text-based heuristic for LaTeX delimiters (`$...$`, `\(...\)`, `$$...$$`), LaTeX command tokens (`\frac`, `\sum`, etc.), and labelled references (`Equation 1.2`, `Figure 3`, `Table 4.1`).
- Wired the classifier into each reader's `activeParagraph` subscription — calls `useVisualCueStore.setVisualCue(...)` based on the active paragraph's text.
- 8 component-render tests + 10 classifier tests + 4 reader-screen mount tests.

#### G15 — design note

The electron `<TTSVisualCue />` consumes a DOM-walker (`detectVisualsNear`) that scans `<math>`, `<figure>`, `<img>` siblings of the active paragraph element. On mobile:

- **EPUB:** the active paragraph is rendered inside an epubjs WebView; we'd need a postMessage bridge to inject the scanner and stream `visual-nearby` events back. That's a bigger change than Batch 8's scope.
- **MOBI/AZW3:** chunker yields plain text (no DOM at all).
- **PDF:** chunker yields plain text per page (no DOM either).
- **DJVU:** chunker yields OCR'd text from djvu.js (no DOM).

For all four formats, a text classifier is the right level of effort for the first cue surface — it catches LaTeX math and labelled references which are the high-value cases. A DOM-scanning EPUB path remains parked as a future follow-up. Documented for Loop B.

### G17 — EPUB "Read from here" (commit e017b57b)

- New `lib/epub/read-aloud-from-selection.ts` mirroring the PDF resolver. Text-first paragraph match (matches the PDF behaviour) with a CFI-based fallback via shared `findParagraphForCfi`.
- Added "Read from here" menu item to the EPUB selection context menu in `app/reader/[id].tsx`. Seeds the player from book chunks if needed, then dispatches `PLAY_FROM` with the partial-first payload from shared `buildPartialFirst`.
- 5 resolver tests in `__tests__/tts/epub-read-from-selection.test.tsx`.

### G09 — PDF polish: thumbnails + Android go-to-page (commit 16e34dca)

- Re-linked the existing `app/reader/pdf/thumbnail-modal.tsx` into the new WebView-based PDF reader's toolbar (Batch 5 left it orphaned). Added a grid icon button in the PDF top bar.
- New `components/pdf/GoToPageModal.tsx`: RN `<Modal>` + `<TextInput>` for Android. iOS keeps `Alert.prompt`. Validation extracted to `goto-page-validate.ts` so it's testable without rendering RN.
- 10 validation tests + 1 source-level wiring test in `__tests__/pdf/goto-page-android.test.tsx`.

### G10 — Undo snackbar + NOTE_COLOR_NONE (commit e6bb3780)

- New `hooks/useUndoSnackbar.ts`: single-slot ring with 5s auto-dismiss. Mirrors electron's `useUndoableHighlightShortcut` semantics (no Cmd-Z binding since mobile has no keyboard shortcuts).
- New `components/UndoSnackbar.tsx`: positioned snackbar with a single action button + dismiss. Reanimated fade-in/out.
- Wired into both EPUB (`app/reader/[id].tsx`) and PDF (`app/reader/pdf/[id].tsx`) delete-highlight paths. Tap "Undo" → `restoreHighlight(id)` flips `isDeleted` back, reader re-paints the annotation.
- Re-exported `NOTE_COLOR_NONE` and `isNoteOnly` from `types/highlight.ts`. The mobile palette still excludes the sentinel from the UI picker per Batch 7 Decision 3 (no schema migration yet), but call sites can now reference it for sync / future note-first surfaces.
- 6 snackbar hook tests + 3 NOTE_COLOR_NONE re-export tests.

### N01 — X-Dev-Bypass header (commit 661014b8)

- New `lib/api-dev-bypass.ts` with `buildDevBypassHeaders` + `readDevBypassSecret` helpers.
- Reads secret from `Constants.expoConfig.extra.devBypassSecret` with a `process.env.DEV_BYPASS_SECRET` fallback for tests/CI.
- Injected into `lib/api.ts` apiClient when `__DEV__ === true` AND a secret is configured. Production builds never see the header.
- Mirrors electron's behaviour at `apps/rishi-electron/src/renderer/src/lib/api.ts:338`.
- 7 tests (5 builder + 2 secret-reader).

### N08 — MOBI/AZW3 cover extraction (commit f51de75d)

- Exported `extractMobiCover(buf)` from `@rishi/shared/formats/mobi` returning the same `{ mimeType, data }` shape `extractEpubCover` returns. Thin wrapper around the existing internal extractor (renamed `extractMobiCover_impl`).
- Mobile CoverPort now handles `format === "epub" || "mobi" || "azw3"`. The `readEpubBytes` injection point renamed to `readBookBytes` (format-agnostic). EPUB still uses `extractEpubCover`; MOBI + AZW3 use the new shared `extractMobiCover`.
- 6 shared tests covering JPEG/PNG/GIF extraction, "no image record", "too-small buffer", "unrecognised magic".
- DJVU first-page raster cover deferred — the djvu.js cover extraction would require either (a) a WebView round-trip with `react-native-view-shot` capturing page 1, or (b) a heuristic that decodes the djvu.js IFF "Tinf" thumbnail record. Both are large enough to need their own batch. Same trade-off as PDF (covered in N08 source).

## Verification results

| Gate                                | Baseline (pre-Batch-8) | After Batch 8           |
| ----------------------------------- | ---------------------- | ----------------------- |
| `npx tsc --noEmit` in `apps/mobile` | 20 errors              | **20 errors**           |
| `npx jest` in `apps/mobile`         | 375 / 377 pass         | **432 / 434 pass**      |
| `pnpm -C packages/shared test`      | 474 / 474 pass         | **480 / 480 pass**      |
| `pnpm -C apps/rishi-electron typecheck` | clean              | **clean**               |

The 2 jest failures are the same pre-existing baseline failures every batch note has called out (`guardrails.test.ts` off-topic mock + `vector.test.ts` execSync assertion). No new test failures were introduced.

Mobile TS error count is identical (the 2 transient TS7016 errors from `react-test-renderer` were resolved by adding `@types/react-test-renderer` as a dev-dep — commit 1330511e).

## Packages installed

- `@types/react-test-renderer@^19.1.0` (devDep, apps/mobile) — typings for `react-test-renderer` so the new hook tests typecheck cleanly.

No runtime deps added.

## Commits

1. `51c90d83` — feat(mobile-parity-batch-8): wire page-capture refs (G20) + TTS chat-bridge in MOBI/DJVU (G14)
2. `13e10c44` — feat(mobile-parity-batch-8): render TTSVisualCue + drive setVisualCue (G15)
3. `e017b57b` — feat(mobile-parity-batch-8): EPUB "Read from here" selection action (G17)
4. `16e34dca` — feat(mobile-parity-batch-8): PDF polish — thumbnail modal + Android go-to-page (G09)
5. `e6bb3780` — feat(mobile-parity-batch-8): EPUB highlights polish — undo snackbar + NOTE_COLOR_NONE (G10)
6. `661014b8` — feat(mobile-parity-batch-8): X-Dev-Bypass header on mobile apiClient (N01)
7. `f51de75d` — feat(mobile-parity-batch-8): MOBI/AZW3 cover extraction in CoverPort (N08)
8. `1330511e` — chore(mobile): add @types/react-test-renderer for batch 8 page-capture / undo-snackbar tests

## Files added/modified

### Added (15)

- `apps/mobile/hooks/usePageCaptureRef.ts`
- `apps/mobile/hooks/useUndoSnackbar.ts`
- `apps/mobile/lib/tts/visual-cue-classify.ts`
- `apps/mobile/lib/epub/read-aloud-from-selection.ts`
- `apps/mobile/lib/api-dev-bypass.ts`
- `apps/mobile/components/UndoSnackbar.tsx`
- `apps/mobile/components/pdf/GoToPageModal.tsx`
- `apps/mobile/components/pdf/goto-page-validate.ts`
- `apps/mobile/__tests__/voice-chat/page-capture-refs.test.tsx`
- `apps/mobile/__tests__/tts/visual-cue.test.tsx`
- `apps/mobile/__tests__/tts/visual-cue-classify.test.ts`
- `apps/mobile/__tests__/tts/epub-read-from-selection.test.tsx`
- `apps/mobile/__tests__/pdf/goto-page-android.test.tsx`
- `apps/mobile/__tests__/highlights/undo-snackbar.test.tsx`
- `apps/mobile/__tests__/highlights/note-color-none.test.ts`
- `apps/mobile/__tests__/api/dev-bypass.test.ts`

### Modified (10)

- `apps/mobile/app/reader/[id].tsx`
- `apps/mobile/app/reader/pdf/[id].tsx`
- `apps/mobile/app/reader/mobi/[id].tsx`
- `apps/mobile/app/reader/djvu/[id].tsx`
- `apps/mobile/lib/api.ts`
- `apps/mobile/lib/book-import/adapters.ts`
- `apps/mobile/types/highlight.ts`
- `apps/mobile/__tests__/tts/chat-bridge.test.ts`
- `apps/mobile/package.json` + `package-lock.json`
- `packages/shared/src/formats/mobi.ts`
- `packages/shared/src/formats/mobi.test.ts`

## Deviations & rationale

### Used `react-test-renderer` instead of `@testing-library/react-native`

The mobile project's jest config runs in the `node` environment without a `react-native` preset transform — so importing `react-native` directly inside a test file throws an `ESM syntax error` from `node_modules/react-native/index.js`. The existing pattern (see `__tests__/settings/settings.test.tsx`) mocks `react-native` at the module level and renders with `react-test-renderer`. Batch 8 follows that pattern.

### Visual-cue heuristic is text-based, not DOM-based

See "G15 — design note" above. The shared `detectVisualsNear` requires a live DOM tree. Mobile chunks are plain text. A WebView postMessage bridge for EPUB would be a meaningful refactor; the text classifier catches the high-value cases (LaTeX math, labelled references) with very little code and no IPC.

### MOBI cover extractor renaming

To export a public `extractMobiCover(buf)` matching `extractEpubCover`'s shape, I renamed the existing internal helper to `extractMobiCover_impl` and added a thin public wrapper. The only internal caller (`parseMobiMetadata`) was updated.

### CoverPort injection-point rename

`readEpubBytes` was renamed to `readBookBytes` because MOBI/AZW3 use the same I/O path. No test code referenced the old name; the field is constructor-injection-only and lives entirely inside `lib/book-import/adapters.ts`.

### "Read from here" available even without prior TTS seeding

The EPUB resolver seeds the player from book chunks on first use if `currentParagraphs` is empty. The PDF resolver requires the WebView's `getPageText` to have returned paragraphs (Batch 5 wiring). Behaviourally consistent: the user gets the same affordance regardless of format.

## What I did NOT touch

- Electron source (`apps/rishi-electron/src/**`) — verified read-only constraint via electron typecheck after each commit.
- Voice-chat FSM, key cache, activation pipeline — fully shared, no mobile-only changes needed.
- DJVU cover extraction — deferred, documented in N08 commit.
- The 2 pre-existing baseline jest failures — out of scope.

## Loop A status

VERIFICATION.md called Loop A done with 23 closed / 7 partial / 2 open. Batch 8 closes 6 of the 7 partials, leaving:

- **G15** — still "partial" because of the design note above (text-based vs DOM-based). The render path + driver are both shipped; only the DOM-scanner is missing.
- **G19, G22** — P3, deferred by design (require Expo SDK 55 `react-native-worklets >= 0.6`).
- **G30, G31** — P3, explicitly excluded by design from Loop A.

Loop A is solidly done. Loop B can focus on: (a) full architecture catch-up (G24/G25 stores + machines), (b) optional WebView DOM-scanner for G15, (c) DJVU cover, (d) the deferred P3 work when SDK 55 lands.
