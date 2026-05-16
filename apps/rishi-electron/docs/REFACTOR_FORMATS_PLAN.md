# DRY Refactor: EPUB / MOBI / AZW3 Reader Views

> Generated: 2026-05-16
> Working directory: `apps/rishi-electron`
> All paths are relative to that root unless marked absolute.

---

## Pre-flight checks

Before touching any code, run the full quality gate and record the baseline:

```
pnpm test 2>&1 | tee /tmp/baseline-test.txt
pnpm lint
pnpm typecheck
```

All three must be green. If anything is already red, fix it before starting — this refactor must never be blamed for a pre-existing failure.

---

## Wave 1 — Renderer-side alias setup

### T01 — Add `hasIndexedBookData` alias next to `hasSavedEpubData` in `api.ts`
- **Files:** `src/renderer/src/lib/api.ts`
- **AC:** `export async function hasIndexedBookData` exists and delegates to `api().hasSavedEpubData(params.bookId)`. The original `hasSavedEpubData` export is preserved unchanged.
- **Gate:** `pnpm lint && pnpm typecheck && pnpm test`
- **Commit:** `refactor(electron): add hasIndexedBookData alias in api.ts (renderer-side only)`
- **Deps:** none
- **Risk:** The IPC channel name `hasSavedEpubData` on the preload/main side is NOT changed. Only the renderer-side function name is aliased.

---

## Wave 2 — Test scaffolding (all seven primitives in parallel)

Write failing test files. Each must be runnable and produce at least one failing assertion. No implementation yet.

### T02 — Failing tests for `useBookSyncId`
- **Files:** `src/renderer/src/hooks/reader/__tests__/useBookSyncId.test.ts` (create)
- **AC:** Tests assert (1) calls `window.electron.booksGetSyncId(bookId)` on mount; (2) exposes `bookSyncId` state that updates when IPC resolves; (3) `bookSyncIdRef.current` is set to the same value; (4) `publishBookmarksToMenu` called once `bookSyncId` is non-empty. All red.
- **Gate:** lint + typecheck pass; tests expected to fail on the new file.
- **Commit:** `test(electron): add failing tests for useBookSyncId`
- **Deps:** none
- **Risk:** Mock `@/modules/bookmark-storage` to intercept `publishBookmarksToMenu`. Use `renderHook` from `@testing-library/react`.

### T03 — Failing tests for `useReaderMenuSync`
- **Files:** `src/renderer/src/hooks/reader/__tests__/useReaderMenuSync.test.ts` (create)
- **AC:** Tests assert (1) calls `window.electron.send('window:setBookTitle', ...)` when book changes; (2) calls `window.electron.setMenuContext({ tocOpen })` when `tocOpen` changes; (3) subscribes to `playerStore.playingState` and calls `setMenuContext({ isReading: true })` when state becomes `'playing'`. All red.
- **Commit:** `test(electron): add failing tests for useReaderMenuSync`
- **Risk:** Add `setMenuContext: vi.fn()` to `mockElectronAPI` in `src/renderer/src/test-setup.ts` as part of this task.

### T04 — Failing tests for `useCommonMenuHandlers`
- **Files:** `src/renderer/src/hooks/reader/__tests__/useCommonMenuHandlers.test.ts` (create)
- **AC:** Tests assert (1) `toggleTOC` calls `setTocOpen` toggle; (2) `readAloudToggle` dispatches `PAUSE` when playing, `RESUME` when paused, calls `requireAuth('tts', ...)` otherwise; (3) `openChat` calls `requireAuth('chat', ...)`; (4) `voiceChat` toggles `isChatting` via store. All red.
- **Commit:** `test(electron): add failing tests for useCommonMenuHandlers`
- **Risk:** Returned object must be stable across re-renders (memoized). Test referential stability with two `renderHook` calls.

### T05 — Failing tests for `useChapterParagraphPrefetch`
- **Files:** `src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts` (create)
- **AC:** (1) calls `fetchCurrent` immediately, pipes to `setCurrentParagraphs`; (2) debounces next/prev by 300 ms (fake timers); (3) skip next at last chapter; (4) skip prev at first chapter; (5) clears next/prev on unmount. All red.
- **Commit:** `test(electron): add failing tests for useChapterParagraphPrefetch`
- **Risk:** `fetchCurrent` / `fetchAt` accessed via refs internally (React Compiler safety).

### T06 — Failing tests for `usePageRequestSubscription`
- **Files:** `src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts` (create)
- **AC:** (1) subscribes to `playerStore.pageRequest`; (2) calls `onNext` for `'next'`; (3) calls `onPrev` for `'prev'`; (4) when `autoClear: true`, calls `clearPageRequest` after dispatch; (5) when `autoClear: false`, does NOT call `clearPageRequest`. All red.
- **Commit:** `test(electron): add failing tests for usePageRequestSubscription`
- **Risk:** `onNext`/`onPrev` accessed via refs. New callback reference must NOT re-subscribe.

### T07 — Failing tests for `ReaderOverlayControls`
- **Files:** `src/renderer/src/components/reader/__tests__/ReaderOverlayControls.test.tsx` (create)
- **AC:** (1) renders `VoiceChatLauncher`; (2) renders `TTSControls` with `bookId`; (3) renders `AIChatOrb` only when `isChatting: true`; (4) `TTSControls` wrapper has `display: none` when chatting, `display: contents` otherwise; (5) `AIChatOrb` receives `chatStatus` from store and forwarded `onChatOrbClick`. All red.
- **Commit:** `test(electron): add failing tests for ReaderOverlayControls`
- **Risk:** Mock `TTSControls`, `AIChatOrb`, `VoiceChatLauncher` with `vi.mock` stubs.

### T08 — Failing tests for `useBookEmbeddings`
- **Files:** `src/renderer/src/hooks/reader/__tests__/useBookEmbeddings.test.ts` (create)
- **AC:** (1) calls `hasIndexedBookData({ bookId })` when `ready` is true; (2) skips `indexBook` if already indexed; (3) calls `buildPageData()` and passes result to `indexBook`; (4) `embeddingsProcessedRef` guard prevents second run on re-render; (5) noop when `ready: false`. All red.
- **Commit:** `test(electron): add failing tests for useBookEmbeddings`
- **Deps:** T01

---

## Wave 3 — Implementations

### T09 — Implement `useBookSyncId`
- **Files:** `src/renderer/src/hooks/reader/useBookSyncId.ts` (create)
- **AC:** T02 green. Signature: `useBookSyncId(bookId: number): { bookSyncId: string; bookSyncIdRef: RefObject<string | null> }`. Two effects: fetch → set state+ref; publish bookmarks keyed on `bookSyncId`.
- **Commit:** `refactor(electron): implement useBookSyncId hook`
- **Deps:** T02

### T10 — Implement `useReaderMenuSync`
- **Files:** `src/renderer/src/hooks/reader/useReaderMenuSync.ts` (create)
- **AC:** T03 green. Signature: `useReaderMenuSync({ book: { id: number; title: string }, tocOpen: boolean }): void`. All `window as unknown as` casts local to this file.
- **Commit:** `refactor(electron): implement useReaderMenuSync hook`
- **Deps:** T03

### T11 — Implement `useCommonMenuHandlers`
- **Files:** `src/renderer/src/hooks/reader/useCommonMenuHandlers.ts` (create)
- **AC:** T04 green. Returns `Pick<MenuCommandHandlers, 'toggleTOC' | 'readAloudToggle' | 'openChat' | 'voiceChat'>`. Wrapped in `useMemo`. Callbacks via refs internally.
- **Commit:** `refactor(electron): implement useCommonMenuHandlers hook`
- **Deps:** T04

### T12 — Implement `useChapterParagraphPrefetch`
- **Files:** `src/renderer/src/hooks/reader/useChapterParagraphPrefetch.ts` (create)
- **AC:** T05 green. Internal refs for `fetchCurrent` and `fetchAt`. Cleanup clears next/prev. JSDoc: "ref-based callbacks (React Compiler safe)".
- **Commit:** `refactor(electron): implement useChapterParagraphPrefetch hook`
- **Deps:** T05
- **Risk:** Owns construction of `ParagraphWithIndex` from raw `string[]` returned by callbacks, using `indexPrefix`.

### T13 — Implement `usePageRequestSubscription`
- **Files:** `src/renderer/src/hooks/reader/usePageRequestSubscription.ts` (create)
- **AC:** T06 green. `onNext`/`onPrev` accessed via refs. Subscribes once.
- **Commit:** `refactor(electron): implement usePageRequestSubscription hook`
- **Deps:** T06

### T14 — Implement `ReaderOverlayControls`
- **Files:** `src/renderer/src/components/reader/ReaderOverlayControls.tsx` (create)
- **AC:** T07 green. Props: `{ bookId: string; chatPanelOpen: boolean; onChatOrbClick: () => void }`. Reads stores internally.
- **Commit:** `refactor(electron): implement ReaderOverlayControls component`
- **Deps:** T07

### T15 — Implement `useBookEmbeddings`
- **Files:** `src/renderer/src/hooks/reader/useBookEmbeddings.ts` (create)
- **AC:** T08 green. Signature: `useBookEmbeddings({ bookId, ready, buildPageData }): void`. Uses `hasIndexedBookData` not `hasSavedEpubData`. `buildPageData` via ref.
- **Commit:** `refactor(electron): implement useBookEmbeddings hook`
- **Deps:** T08, T01

### T16 — Unify `extractMobiData` + `extractAzw3Data` into `extractKindleData`
- **Files:** `src/main/ipc/formats.ts`
- **AC:** New `extractKindleData(filePath: string, kind: 'mobi' | 'azw3'): Promise<BookDataResult>`. `'mobi'` path no try/catch; `'azw3'` wraps `parseMobiMetadata` in try/catch. Both `extract*Data` wrappers reduced to one-line delegators (or removed if call sites updated directly). IPC handler registrations unchanged.
- **Commit:** `refactor(electron): unify extractMobiData + extractAzw3Data into extractKindleData`
- **Deps:** none

---

## Wave 4 — MOBI migrations (sequential — same file)

Each task touches ONLY `src/renderer/src/components/mobi/MobiView.tsx`.

### T17 — Migrate `useBookSyncId` into MobiView
- **AC:** Remove `booksGetSyncId` effect and publish-bookmarks effect. Replace with `const { bookSyncId, bookSyncIdRef } = useBookSyncId(book.id)`. `git grep "booksGetSyncId" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useBookSyncId into MobiView`
- **Deps:** T09

### T18 — Migrate `useReaderMenuSync` into MobiView
- **AC:** `git grep "window:setBookTitle\|setMenuContext" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useReaderMenuSync into MobiView`
- **Deps:** T10, T17

### T19 — Migrate `useCommonMenuHandlers` into MobiView
- **AC:** `git grep "readAloudToggle" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0. Spread the hook's result + local `addBookmark` into `useMenuCommands`.
- **Commit:** `refactor(electron): migrate useCommonMenuHandlers into MobiView`
- **Deps:** T11, T18

### T20 — Migrate `useChapterParagraphPrefetch` into MobiView
- **AC:** Remove prefetch effect and `prefetchTimerRef`. Pass `indexPrefix: 'mobi'`. `fetchCurrent`/`fetchAt` call `getMobiText({ path, chapterIndex })`. `git grep "prefetchTimerRef" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useChapterParagraphPrefetch into MobiView`
- **Deps:** T12, T19
- **Risk:** Preserve paragraph index format `mobi-${chapterIndex}-${i}` exactly.

### T21 — Migrate `usePageRequestSubscription` into MobiView
- **AC:** Remove pageRequest subscribe effect. `autoClear: true`. `git grep "handleNextEmptied\|handlePrevEmptied" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate usePageRequestSubscription into MobiView`
- **Deps:** T13, T20

### T22 — Migrate `ReaderOverlayControls` into MobiView
- **AC:** Replace the 3 overlay JSX elements with `<ReaderOverlayControls .../>`. Drop local `isChatting`/`chatStatus` subscriptions. `git grep "AIChatOrb\|VoiceChatLauncher" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate ReaderOverlayControls into MobiView`
- **Deps:** T14, T21

### T23 — Migrate `useBookEmbeddings` into MobiView
- **AC:** Remove embeddings effect and `embeddingsProcessedRef`. `git grep "embeddingsProcessedRef\|hasSavedEpubData" src/renderer/src/components/mobi/MobiView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useBookEmbeddings into MobiView`
- **Deps:** T15, T22

---

## Wave 5 — AZW3 migrations (sequential — same file)

Each task touches ONLY `src/renderer/src/components/azw3/Azw3View.tsx`.

### T24 — Migrate `useBookSyncId` into Azw3View
- **AC:** `git grep "booksGetSyncId" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0. `addBookmark` handler reads `bookSyncIdRef.current` from the hook's ref.
- **Commit:** `refactor(electron): migrate useBookSyncId into Azw3View`
- **Deps:** T09

### T25 — Migrate `useReaderMenuSync` into Azw3View
- **AC:** `git grep "window:setBookTitle\|setMenuContext" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useReaderMenuSync into Azw3View`
- **Deps:** T10, T24

### T26 — Migrate `useCommonMenuHandlers` into Azw3View
- **AC:** `git grep "readAloudToggle" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0. Keep `addBookmark` (uses `formatLocation(idx, pageWithinChapter)`) local.
- **Commit:** `refactor(electron): migrate useCommonMenuHandlers into Azw3View`
- **Deps:** T11, T25

### T27 — Migrate `useChapterParagraphPrefetch` into Azw3View
- **AC:** Remove prefetch effect and `prefetchTimerRef`. Pass `indexPrefix: 'azw3'`. `fetchCurrent`/`fetchAt` call `extractSectionParagraphs(sections[idx])` and return `string[]` (handle missing section by returning `[]`).
- **Commit:** `refactor(electron): migrate useChapterParagraphPrefetch into Azw3View`
- **Deps:** T12, T26

### T28 — Migrate `usePageRequestSubscription` into Azw3View
- **AC:** Remove pageRequest subscribe effect. `autoClear: true`. `git grep "clearPageRequest" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate usePageRequestSubscription into Azw3View`
- **Deps:** T13, T27
- **Risk:** `goNextPage`/`goPrevPage` close over `pendingPageAfterLoadRef`. Ref-based callback access prevents re-subscription.

### T29 — Migrate `ReaderOverlayControls` into Azw3View
- **AC:** `git grep "AIChatOrb\|VoiceChatLauncher" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate ReaderOverlayControls into Azw3View`
- **Deps:** T14, T28

### T30 — Migrate `useBookEmbeddings` into Azw3View
- **AC:** Remove embeddings effect. `git grep "embeddingsProcessedRef\|hasSavedEpubData" src/renderer/src/components/azw3/Azw3View.tsx | wc -l` returns 0. `buildPageData` callback contains the full `virtualGroupId` dedup logic.
- **Commit:** `refactor(electron): migrate useBookEmbeddings into Azw3View`
- **Deps:** T15, T29

---

## Wave 6 — EPUB migrations (sequential — same file)

EPUB does NOT use primitives 4 (`useChapterParagraphPrefetch`) or 7 (`useBookEmbeddings`) — its paragraph path is via `epubStore`. Only primitives 1, 2, 3, 5, 6 migrate here.

### T31 — Migrate `useBookSyncId` into EpubView
- **AC:** Remove `booksGetSyncId` effect and separate `publishBookmarksToMenu` effect. `git grep "booksGetSyncId" src/renderer/src/components/epub/EpubView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useBookSyncId into EpubView`
- **Deps:** T09

### T32 — Migrate `useReaderMenuSync` into EpubView
- **AC:** `git grep "window:setBookTitle\|setMenuContext" src/renderer/src/components/epub/EpubView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate useReaderMenuSync into EpubView`
- **Deps:** T10, T31

### T33 — Migrate `useCommonMenuHandlers` into EpubView
- **AC:** `git grep "readAloudToggle" src/renderer/src/components/epub/EpubView.tsx | wc -l` returns 0. EPUB's `addBookmark` (uses `bookSyncId`, `currentLocation`, `pageCurrent`, `queryClient`) remains local.
- **Commit:** `refactor(electron): migrate useCommonMenuHandlers into EpubView`
- **Deps:** T11, T32

### T34 — Migrate `usePageRequestSubscription` into EpubView
- **AC:** Extract `pageRequest` subscription from the large `useEffect([rendition])` block via `usePageRequestSubscription({ onNext: tryConsumePageRequest, onPrev: tryConsumePageRequest, autoClear: false })`. `autoClear: false` because `tryConsumePageRequest` clears internally. The navState retry subscription (`unsubNavRetry`) STAYS in its original effect — it is not part of this primitive. `git grep "s.pageRequest" src/renderer/src/components/epub/EpubView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate usePageRequestSubscription into EpubView`
- **Deps:** T13, T33
- **Risk:** `tryConsumePageRequest` is async and defined inside `useEffect([rendition])`. Solution: pass a ref-stable wrapper that early-returns when `rendition` is null. Hook is called at the top level, not inside the effect.

### T35 — Migrate `ReaderOverlayControls` into EpubView
- **AC:** `git grep "AIChatOrb\|VoiceChatLauncher" src/renderer/src/components/epub/EpubView.tsx | wc -l` returns 0.
- **Commit:** `refactor(electron): migrate ReaderOverlayControls into EpubView`
- **Deps:** T14, T34

---

## Wave 7 — Final cleanup

### T36 — Drop `hasSavedEpubData` import from view files
- **Files:** `MobiView.tsx`, `Azw3View.tsx` (and `EpubView.tsx` if applicable)
- **AC:** `git grep "hasSavedEpubData" src/renderer/src/components/{mobi,azw3,epub}/*.tsx | wc -l` returns 0. Function still exists in `src/renderer/src/lib/api.ts`.
- **Commit:** `refactor(electron): remove hasSavedEpubData from reader view imports`
- **Deps:** T23, T30, T35

### T37 — Final verification grep sweep
- **Files:** none (verification only)
- **AC:** All of the following greps return 0 across `mobi/MobiView.tsx`, `azw3/Azw3View.tsx`, `epub/EpubView.tsx`: `booksGetSyncId`, `publishBookmarksToMenu`, `window:setBookTitle`, `setMenuContext`, `prefetchTimerRef`, `embeddingsProcessedRef`, `AIChatOrb`, `VoiceChatLauncher`, `hasSavedEpubData`, `readAloudToggle`.
- **Commit:** `refactor(electron): final verification pass — all shared blocks extracted`
- **Deps:** T36

---

## Final verification

```bash
# 1. Full quality gate
pnpm lint && pnpm typecheck && pnpm test

# 2. All shared patterns gone from view files
for pattern in booksGetSyncId publishBookmarksToMenu "window:setBookTitle" setMenuContext \
               prefetchTimerRef embeddingsProcessedRef AIChatOrb VoiceChatLauncher \
               hasSavedEpubData readAloudToggle; do
  count=$(git grep "$pattern" \
    src/renderer/src/components/mobi/MobiView.tsx \
    src/renderer/src/components/azw3/Azw3View.tsx \
    src/renderer/src/components/epub/EpubView.tsx 2>/dev/null | wc -l)
  echo "$pattern: $count hits (expect 0)"
done

# 3. New files exist
ls src/renderer/src/hooks/reader/useBookSyncId.ts \
   src/renderer/src/hooks/reader/useReaderMenuSync.ts \
   src/renderer/src/hooks/reader/useCommonMenuHandlers.ts \
   src/renderer/src/hooks/reader/useChapterParagraphPrefetch.ts \
   src/renderer/src/hooks/reader/usePageRequestSubscription.ts \
   src/renderer/src/hooks/reader/useBookEmbeddings.ts \
   src/renderer/src/components/reader/ReaderOverlayControls.tsx
```
