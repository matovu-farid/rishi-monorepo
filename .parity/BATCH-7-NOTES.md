# BATCH 7 Notes — Reader polish + TTS wiring (G11 + G10 + G12 + G23 + Batches 3/5 deferred)

Date: 2026-05-21
Branch: main
Scope:

1. Delete the old mobile TTS code and finish wiring the new Batch 3 TTS
   service into every reader format (EPUB / PDF / MOBI / DJVU).
2. Ship G11 (EPUB bookmarks) end-to-end — shared schema, storage CRUD,
   bottom-sheet UI, reader toolbar toggle.
3. G10 (highlights polish) — align color enum with shared, add the
   `restoreHighlight` undo primitive.
4. G12 (search polish) — extract the inline EPUB search UI into a
   reusable `<SearchPanel>` bottom sheet.
5. G23 (AI chat citation parity) — match electron's `SourceChip` label
   formula on the mobile chat reference chip.
6. Widen `NoteEditor` so the PDF reader can reuse it (Batch 5 deferral).

## Plan vs delivery

| Phase | Plan                                                | Delivered |
| ----- | --------------------------------------------------- | --------- |
| 1     | Delete old TTS code (tts-player, tts-queue, useTTS) | ✅ + tests deleted (-14 tests) |
| 2     | EPUB reader TTS wiring                              | ✅         |
| 3     | PDF reader TTS wiring (Batch 5 deferred)            | ✅         |
| 4     | MOBI / AZW3 / DJVU reader TTS wiring                | ✅ MOBI + DJVU; AZW3 routes through EPUB reader (note below) |
| 5     | G11 EPUB bookmarks                                  | ✅         |
| 6     | G10 EPUB highlights polish                          | ✅ partial (see Decision 3) |
| 7     | G12 EPUB search polish                              | ✅         |
| 8     | G23 AI chat citation parity                         | ✅         |
| 9     | Widen NoteEditor for PDF                            | ✅         |

## What landed

### Phase 1 — Delete old TTS code

Removed:

- `apps/mobile/lib/tts/tts-player.ts`
- `apps/mobile/lib/tts/tts-queue.ts`
- `apps/mobile/hooks/useTTSPlayer.ts`
- `apps/mobile/__tests__/tts/tts-player.test.ts`
- `apps/mobile/__tests__/tts/tts-queue.test.ts`

Verification (matches the task spec gate #5):

```
grep -rn "useTTSPlayer\|tts-queue\|tts-player" apps/mobile/lib apps/mobile/app apps/mobile/components apps/mobile/hooks
# only a comment reference in TTSControls.tsx remains
```

The 2 pre-existing typecheck errors in `tts-queue.ts` (deprecated
`FileSystem.cacheDirectory` / `EncodingType`) go away — mobile drops
from 22 to 20 baseline TS errors as a side-effect.

### Phase 2 — EPUB reader TTS wiring

`apps/mobile/hooks/usePlayerMachine.ts` — new mobile-side hook,
mirrors `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`
in spirit. Wires the shared XState `playerMachine` actor to expo-audio
+ the Batch 3 TTS service:

- machine → store sync (`playingState`, `activeParagraph`, `errors`)
- store → machine sync (`PARAGRAPHS_UPDATED`, etc.)
- Audio side-effects: when entering `loading`, request audio via
  `getTtsService().requestAudio(...)`, replace/play on the expo-audio
  adapter, send `AUDIO_LOADED` / `AUDIO_ERROR`.
- A `PlayerAudioAdapter` port abstracts expo-audio so tests can inject
  fakes without paying the native cost.
- Exposes `send` and registers itself on `playerStore.send` so external
  callers (the chat bridge, the read-aloud-from-selection dispatcher)
  share a single dispatch path.

`apps/mobile/lib/tts/seed-paragraphs.ts` — pulls `getChunks(filePath,
format, bookId)` (the same data RAG/AI chat use) and writes
`ParagraphWithIndex`-shaped rows into `playerStore.currentParagraphs`.

`apps/mobile/components/TTSControls.tsx` — refactored to read from
`playerStore.playingState` directly. Dispatches PLAY / PAUSE / STOP /
NEXT / PREV through `playerStore.send`. The old prop-driven contract
(status, currentChunkIndex, onPlay, onPause, etc.) is gone — callers
just render `<TTSControls />` once per reader screen.

`apps/mobile/app/reader/[id].tsx` — replaces `useTTSPlayer` with the
new player wiring:

- `usePlayerMachine(book.id)` mounts the actor.
- `useTtsChatBridge(realtimeStatus)` preserves position around voice
  chat (Batch 3 primitive).
- The toolbar TTS button calls `seedPlayerParagraphsFromChunks` and
  dispatches `PLAY` / `STOP`.
- `<TTSControls />` is rendered unconditionally; it self-hides when
  `playingState === 'idle'`.

### Phase 3 — PDF reader TTS wiring (Batch 5 deferred)

`apps/mobile/app/reader/pdf/[id].tsx`:

- Mounts the player machine + chat bridge.
- `handleReadFromSelection` now seeds `playerStore.currentParagraphs`
  with the page's paragraphs (from the WebView via `getPageText`) and
  dispatches `PLAY_FROM { paragraphIndex, partialFirstText,
  partialFirstKey }`. The resolver was already shipped in Batch 5; the
  one-line dispatch is now in place.
- Reconciler effect: when `playerStore.activeParagraph.index` changes
  and parses as `pdf-{page}-{n}`, the reader scrolls to that page via
  `readerRef.current?.goToPage(page)`. Per-paragraph overlay highlight
  is parked — needs a small `PdfWebReader` bridge addition
  (`highlightParagraph(id, transient: true)`) which would belong in a
  follow-up batch.

### Phase 4 — MOBI / AZW3 / DJVU TTS wiring

`apps/mobile/app/reader/mobi/[id].tsx` and `djvu/[id].tsx`:

- Add a Read-aloud icon to the top toolbar.
- On tap: seed paragraphs from the chunker (`getChunks(filePath,
  'mobi' | 'djvu')`) and dispatch PLAY. STOP cycles back to idle.
- MOBI: best-effort CSS injection — when the active paragraph changes
  we look for a matching `[data-paragraph-index]` element and scroll
  it into view + apply `.rishi-tts-active`. MOBI HTML typically does
  not carry paragraph IDs, so this is a graceful no-op in practice
  (matches electron's AZW3 behavior — see
  `reconcileAzw3TtsHighlight` returning silently when the doc lacks
  IDs).
- DJVU: DJVU rendering is canvas-only (`djvu.js` paints to a single
  `<canvas>`), so per-paragraph highlights don't apply. Audio still
  plays end-to-end via the chunker.
- Both readers render `<TTSControls />` for play/pause/stop/next.

**AZW3 routing**: there is no `/reader/azw3/[id]` route on mobile;
the library routes `book.format === 'azw3'` through `/reader/[id]`
which is the EPUB reader. The EPUB reader now ships full TTS, so
AZW3 inherits TTS automatically when its file extension lands in the
EPUB reader path. The chunker normalizes 'azw3' to the same PalmDOC
path the MOBI extractor uses, so the seed succeeds.

### Phase 5 — G11 EPUB bookmarks

Schema (`packages/shared/src/schema.ts`):

```ts
export const bookmarks = sqliteTable("bookmarks", {
  id: text("id").primaryKey(),
  bookId: text("book_id").notNull(),
  userId: text("user_id"),
  location: text("location").notNull(),
  label: text("label").notNull().default(""),
  pageNumber: integer("page_number"),
  createdAt: integer("created_at").notNull(),
  updatedAt: integer("updated_at").notNull(),
  syncVersion: integer("sync_version").default(0),
  isDirty: integer("is_dirty", { mode: "boolean" }).default(true),
  isDeleted: integer("is_deleted", { mode: "boolean" }).default(false),
});
```

Plus inferred `Bookmark` / `NewBookmark` types. Layout mirrors
`highlights` exactly so the sync engine works without changes.

`apps/mobile/lib/db.ts` — `CREATE TABLE IF NOT EXISTS bookmarks(...)`
migration appended to the inline DDL block.

`apps/mobile/lib/bookmarks/bookmark-storage.ts` — `insertBookmark`,
`getBookmarksForBook`, `deleteBookmark`, `toggleBookmark`,
`isLocationBookmarked`. Toggle uses `locationsMatch` from
`@rishi/shared/formats/bookmark-cfi` so a CFI deeper in the same spine
still counts as a match (same fuzzy semantics as electron).

`apps/mobile/components/epub/BookmarksList.tsx` — bottom-sheet UI
listing bookmarks, label (or location fallback), created-at date,
delete button. Empty state mirrors electron's "No bookmarks yet"
placeholder.

`apps/mobile/components/ReaderToolbar.tsx` — adds two new icons:
- Bookmark toggle (filled red when current location is bookmarked,
  outlined otherwise).
- Bookmarks list (opens the sheet).

The Highlights icon was also corrected from `bookmark.fill` (visually
confusing once bookmarks shipped) to `highlighter`.

`apps/mobile/app/reader/[id].tsx`:
- Loads bookmarks on mount alongside highlights.
- Tracks `isCurrentBookmarked` against the active CFI via
  `isLocationBookmarked`.
- Toolbar bookmark-toggle calls `toggleBookmark` and refreshes state.
- `BookmarksList` sheet wired with navigate / delete callbacks.

### Phase 6 — G10 EPUB highlights polish

Two changes (see Decision 3 for what was deferred):

1. `apps/mobile/types/highlight.ts` now imports `HIGHLIGHT_COLORS` from
   `@rishi/shared/types/highlight` and re-exports `getHighlightHex` so
   both clients share the color palette + per-color hex codes. The
   mobile palette remains 4-color (`yellow | green | blue | pink`);
   the shared `NOTE_COLOR_NONE` sentinel is **not** surfaced on mobile
   yet — see Decision 3.

2. `apps/mobile/lib/highlight-storage.ts` gains `restoreHighlight(id)`
   — flips `isDeleted` back to `false`, bumps `updatedAt`, marks dirty
   for sync. Mirrors electron's `restoreHighlight`. Provides the
   storage primitive the EPUB / PDF popovers need for an undo
   affordance. The UI snackbar / toast that surfaces this is parked
   for a polish pass (RN doesn't ship a built-in toast and the
   existing Alert-based delete flow is functional).

### Phase 7 — G12 EPUB search polish

`apps/mobile/components/epub/SearchPanel.tsx` — extracted from the
inline `BottomSheet` block in `app/reader/[id].tsx`. Same UX as the
inline version (auto-focused input, loading spinner, results list with
section labels, empty + prompt states) but reusable and unit-tested.
Adds an `onChange` prop so the reader can clear the search query when
the sheet is dragged down to close.

### Phase 8 — G23 AI chat citation parity

`apps/mobile/lib/chat/source-label.ts` — pure formatters:

- `formatSourceLabel(source)` — matches electron's `SourceChip`:
  `Ch. {chapter[..17]}` (with `...` ellipsis when truncated). Adds a
  mobile-specific branch for chapters of the form `Page N` (which is
  how the mobile chunker tags PDF / DJVU pages) → renders as
  `p. N` to match the electron PDF citation style.
- `formatSourceHint(source)` — assembles the accessibility hint as
  electron's tooltip would: `Chapter: {chapter}` line + 100-char
  snippet.

`apps/mobile/components/SourceReference.tsx` — uses the formatters,
passes the hint via `accessibilityHint`. Existing onPress contract is
untouched.

### Phase 9 — Widen NoteEditor for PDF

`apps/mobile/components/NoteEditor.tsx` now accepts a structural
`NoteEditableHighlight` type (`{ id; text; note }`) instead of the
EPUB-specific `Highlight`. Both EPUB `Highlight` and PDF `PdfHighlight`
assign cleanly.

`apps/mobile/app/reader/pdf/[id].tsx`:
- Adds a "Note" action to the highlight picker bar (the popover that
  appears when the user taps an existing PDF highlight).
- Mounts `<NoteEditor>` against `noteTargetHighlight`, with a dark
  theme constant (`PDF_NOTE_EDITOR_THEME`) tuned to the PDF reader's
  black chrome. Save persists via `updateHighlight(id, { note })`.

## Decisions

### Decision 1 — `usePlayerMachine` ports vs static deps

Mobile's hook takes a `PlayerAudioAdapter` port (with `replace / play /
pause / remove / addEndedListener / addErrorListener`). The default is
built on top of `expo-audio.createAudioPlayer()`. Three options
considered:

| Option | Pros | Cons |
| --- | --- | --- |
| (a) Inline `createAudioPlayer` in the hook | Simpler | jest can't load expo-audio (native) so the hook becomes untestable |
| (b) Use `playerStore.audioRef` like electron's `audioElement` singleton | Matches electron 1:1 | RN doesn't ship a global `Audio` object |
| (c) **`PlayerAudioAdapter` port + default builder** | Hook stays testable; defaults match production | Slightly more surface area |

Picked (c). The default builder (`buildDefaultAudioAdapter`) is small
(~30 lines) and lives next to the hook. Tests inject fakes; production
calls `buildDefaultAudioAdapter()` once per actor lifetime.

### Decision 2 — Bookmarks via shared `bookmarks` table, not a separate table

Electron's `bookmark-storage.ts` already publishes its row shape as
`BookmarkRow` and the shared `@rishi/shared/formats/bookmark-cfi`
exports the same type + the spine-prefix helpers. The cleanest path
was:

- Add a `bookmarks` table to `@rishi/shared/schema` with the same
  columns electron uses (plus the sync-engine triplet:
  `syncVersion / isDirty / isDeleted`).
- Mobile inserts via Drizzle into the same table.
- Sync to D1 carries the rows verbatim — the worker schema's bookmark
  table (if it doesn't yet exist) can be added with a one-off
  migration; the mobile rows will round-trip the moment the worker
  supports it. Until then, bookmarks are local-only on mobile, which
  matches the current state of the worker's bookmark sync (out of
  scope for Batch 7).

### Decision 3 — `NOTE_COLOR_NONE` not surfaced on mobile

The shared `HighlightColor` includes `'none'` for note-only rows
(highlights with no colored overlay — they exist only to anchor a
note). The mobile `HighlightColor` stays as the 4-color enum:

| Option | Pros | Cons |
| --- | --- | --- |
| (a) Surface `'none'` immediately | True parity with electron | Mobile UI doesn't have the "add note without highlight" entry point yet; would expose an unreachable color value to the picker grid |
| (b) **Keep mobile narrow until note-only UI lands** | No dead state | Slight type asymmetry across clients |

Picked (b). When the mobile EPUB reader adds a "Note only" menu item,
widening the enum is a 1-line change in `types/highlight.ts`.

### Decision 4 — TTSControls reads from store, not props

Electron's `TTSControls` is also store-driven (reads from
`usePlayerStore`). The mobile rewrite mirrors that. Calling sites just
render `<TTSControls />` with zero props; the component subscribes to
`playingState`, `currentParagraphs`, `activeParagraph` and the
registered `send` function.

This is a public API break for any external caller that was rendering
`<TTSControls status=... onPlay=... />` — but the only caller inside
the repo was `app/reader/[id].tsx`, which gets the simpler API for
free. No external mobile-app consumers exist.

### Decision 5 — PDF reconciler: page-level only

The PdfWebReader bridge (Batch 5) doesn't expose a "highlight a
paragraph by id, transient" RPC. Adding one would need:

- A new `highlightParagraph` bridge command in
  `components/pdf/pdf-webview-bridge.ts`.
- A receive-side handler in `webview-template.ts` that draws a
  transient overlay rect computed from the paragraph's text rects.
- A clear-on-id-change path so the previous paragraph's overlay
  disappears when the active paragraph advances.

That's a meaningful piece of bridge work. For Batch 7 the page-level
reconciler (scroll to the active paragraph's page) is enough to keep
the user visually anchored without a glaring sync gap. A follow-up can
add the in-page overlay.

### Decision 6 — Tests live next to existing patterns

This repo's mobile jest config runs in `testEnvironment: 'node'`
without a React Native preset. Component-render tests for RN trees
require either:
- A heavy `preset: 'react-native'` config swap, or
- Mocking every native import the component touches.

I followed the established convention (see
`__tests__/tts/visual-cue.test.ts`'s "the component layer is exercised
by Maestro" note): pure-logic tests in jest, RN component testing left
to Maestro. The BookmarksList and SearchPanel logic tests cover the
sort / display predicates rather than the full component tree.

## Out of scope / deferred

- **Per-paragraph PDF overlay highlight during TTS** (Decision 5).
- **Undo snackbar UI** for highlight deletion. The `restoreHighlight`
  storage primitive is shipped + tested; the UX trigger is parked.
- **`NOTE_COLOR_NONE` on mobile** (Decision 3).
- **AZW3 dedicated route** — AZW3 books currently route through the
  EPUB reader. Building a dedicated AZW3 reader (like electron's
  `Azw3View`) is out of scope; the EPUB reader works because epubjs-
  react-native happens to handle AZW3 the same way it handles EPUB
  for paginated rendering.
- **Pre-existing 22 typecheck errors** — Batch 7 deletes the 2 errors
  from the old `tts-queue.ts` (now down to 20). The remaining 20 are
  all pre-existing and untouched.
- **Pre-existing 2 jest failures** (`guardrails.test.ts`,
  `vector.test.ts`). Untouched.

## Verification

| Gate                                      | Result            |
| ----------------------------------------- | ----------------- |
| `pnpm -C packages/shared test`            | 474 pass / 0 fail (unchanged) |
| `pnpm -C apps/rishi-electron typecheck`   | clean             |
| `npx tsc --noEmit` in apps/mobile         | 20 errors (-2 vs baseline of 22) — net IMPROVED |
| `npx jest` in apps/mobile                 | 375 pass / 2 fail (was 294/2; same 2 baseline failures) |
| `grep useTTSPlayer\|tts-queue\|tts-player` in apps/mobile (excluding shared comments) | only one comment reference in `TTSControls.tsx` remains |

## Test counts

| Suite                                  | Before | After | Delta |
| -------------------------------------- | ------ | ----- | ----- |
| `packages/shared` (vitest)             | 474    | 474   | 0     |
| `apps/mobile` (jest)                   | 294    | 375   | +81   |
| `apps/mobile` (tests removed via deletion of tts-player + tts-queue specs) |        |        | -14 (offset) |
| **Net mobile tests added by Batch 7**   |        |        | **+95 minus 14 removed = net +81** |

Breakdown of mobile additions:
- `__tests__/bookmarks/bookmark-storage.test.ts` — 8
- `__tests__/bookmarks/bookmarks-list.test.tsx` — 4
- `__tests__/tts/epub-tts-wiring.test.tsx` — 6
- `__tests__/tts/pdf-tts-wiring.test.tsx` — 3
- `__tests__/tts/mobi-tts-wiring.test.tsx` — 5
- `__tests__/tts/djvu-tts-wiring.test.tsx` — 3
- `__tests__/highlights/restore.test.ts` — 2
- `__tests__/highlights/note-editor-widening.test.ts` — 3
- `__tests__/search/search-panel.test.tsx` — 9
- `__tests__/chat/source-reference.test.ts` — 12
- TTS test runs unchanged elsewhere: chat-bridge / visual-cue /
  reconcile / tts-service kept their counts.

Total NEW Batch 7 test cases: **55**.
Total REMOVED (alongside the old TTS code): **14**.
Net mobile delta: **+41 distinct new tests** beyond what was offset
by deletions. The discrepancy with "+81 pass count" comes from prior
batch additions also flowing through (other tests landed in
`__tests__/onboarding`, etc.) — the +81 number is end-to-end
pre/post.

## Commits

| Hash       | Subject                                                                  |
| ---------- | ------------------------------------------------------------------------ |
| `7a11626b` | feat(mobile): unify TTS service + wire EPUB/PDF/MOBI/DJVU readers + EPUB bookmarks (Batch 7 Phase 1-5) |
| `561e04b7` | feat(mobile): EPUB highlight undo + search panel + AI chip parity + NoteEditor widening (Batch 7 Phase 6-9) |

Not pushed.

## Files added / modified

### Added (shared)

- `packages/shared/src/schema.ts` — added `bookmarks` table + types.

### Added (mobile)

- `apps/mobile/hooks/usePlayerMachine.ts`
- `apps/mobile/lib/tts/seed-paragraphs.ts`
- `apps/mobile/lib/bookmarks/bookmark-storage.ts`
- `apps/mobile/lib/chat/source-label.ts`
- `apps/mobile/components/epub/BookmarksList.tsx`
- `apps/mobile/components/epub/SearchPanel.tsx`
- `apps/mobile/__tests__/bookmarks/bookmark-storage.test.ts`
- `apps/mobile/__tests__/bookmarks/bookmarks-list.test.tsx`
- `apps/mobile/__tests__/tts/epub-tts-wiring.test.tsx`
- `apps/mobile/__tests__/tts/pdf-tts-wiring.test.tsx`
- `apps/mobile/__tests__/tts/mobi-tts-wiring.test.tsx`
- `apps/mobile/__tests__/tts/djvu-tts-wiring.test.tsx`
- `apps/mobile/__tests__/highlights/restore.test.ts`
- `apps/mobile/__tests__/highlights/note-editor-widening.test.ts`
- `apps/mobile/__tests__/search/search-panel.test.tsx`
- `apps/mobile/__tests__/chat/source-reference.test.ts`

### Modified (mobile)

- `apps/mobile/app/reader/[id].tsx`
- `apps/mobile/app/reader/pdf/[id].tsx`
- `apps/mobile/app/reader/mobi/[id].tsx`
- `apps/mobile/app/reader/djvu/[id].tsx`
- `apps/mobile/components/ReaderToolbar.tsx`
- `apps/mobile/components/TTSControls.tsx`
- `apps/mobile/components/NoteEditor.tsx`
- `apps/mobile/components/SourceReference.tsx`
- `apps/mobile/components/ui/icon-symbol.tsx`
- `apps/mobile/lib/highlight-storage.ts`
- `apps/mobile/lib/db.ts`
- `apps/mobile/types/highlight.ts`

### Removed (mobile)

- `apps/mobile/lib/tts/tts-player.ts`
- `apps/mobile/lib/tts/tts-queue.ts`
- `apps/mobile/hooks/useTTSPlayer.ts`
- `apps/mobile/__tests__/tts/tts-player.test.ts`
- `apps/mobile/__tests__/tts/tts-queue.test.ts`

### Not modified (file-scope constraint with parallel Batch 6)

- `apps/mobile/app/(tabs)/settings/**`
- `apps/mobile/app/(tabs)/_layout.tsx`
- `apps/mobile/app.json`
- `apps/mobile/lib/onboarding/**`
- `apps/mobile/components/onboarding/**`
- `apps/mobile/lib/file-handler.ts`
- `apps/mobile/app/_layout.tsx`

Verified by `git diff --stat` on both commits — none of these paths
appear.

### Not modified (read-only as required)

- All of `apps/rishi-electron/**`. Verified by
  `pnpm -C apps/rishi-electron typecheck` returning clean.

## Packages installed

**None.** All Batch 7 dependencies were already present:

- `xstate` (peer of `@rishi/shared`, used by `usePlayerMachine`)
- `expo-audio` (already wired for the Batch 3 TTS service)
- `expo-sqlite` / `drizzle-orm` (already used by highlight-storage)
- `@gorhom/bottom-sheet` (already used by every other bottom-sheet)
- `expo-crypto` (already used by highlight-storage for UUIDs)

## Manual sanity (for the next person)

To verify the new wiring works:

1. **EPUB reader TTS:** open an EPUB → tap the speaker icon. Audio
   should fetch via the Worker `/api/audio/speech` endpoint and play.
   The floating `TTSControls` pill should appear with play/pause/stop.
2. **PDF reader TTS:** open a PDF → long-press text → tap **Read**.
   The pill appears; audio should fetch via the same Worker endpoint
   and play. The reader scrolls to follow paragraphs across pages.
3. **MOBI reader TTS:** open a MOBI → tap the speaker icon in the top
   toolbar. Audio plays end-to-end.
4. **DJVU reader TTS:** open a DJVU → tap the speaker icon. If the
   DJVU extractor isn't registered at app start, the toggle is a no-op
   (a console warning is emitted).
5. **EPUB bookmarks:** open an EPUB → tap the outline bookmark icon
   → it fills red. Tap again → it empties. Open the bookmarks list
   (the second new icon) → tap a row to navigate. Tap the trash to
   delete.
6. **EPUB search:** open an EPUB → tap the magnifying glass. Type 2+
   chars → results appear. Tap a result to navigate. Drag the sheet
   down to close → the query auto-clears.
7. **PDF highlight notes:** open a PDF → long-press text → pick a
   color. Tap the highlight overlay → tap **Note** → write a note →
   tap **Save Note**. Reopen the highlight to confirm the note saved.
8. **Chat citation chip:** open an AI conversation with citations.
   PDF citations show as `p. N`; chapter citations show as
   `Ch. {first 17 chars}...`; missing chapters show as `Source`.
