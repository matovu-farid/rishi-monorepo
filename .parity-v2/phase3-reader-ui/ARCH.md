# Phase 3 — Reader UI Redesign: ARCH.md

Architecture Blueprint — Ready for tester (red) and coder (green)
Date: 2026-05-22

---

## Patterns confirmed from code reading

- Sheet pattern: `sheetRef: React.RefObject<BottomSheet|null>` + `theme: ReaderTheme` passed everywhere
- EPUB screen (`[id].tsx:117-122`): 6 useRef declarations; sheets opened via `snapToIndex(0)` at lines 659, 664, 666, 669, 677; noteEditor at 434
- Auto-hide: EPUB (`[id].tsx:277-285`) pauses for `ttsActive || realtimeActive`. MOBI (`mobi/[id].tsx:292-300`) and DJVU (`djvu/[id].tsx:274-282`) **never check TTS state** (R3 bug)
- PDF (`pdf/[id].tsx:95`): `toolbarVisible` starts `true`, no auto-hide
- TTSControls (`TTSControls.tsx:64`): `bottom: insets.bottom + 16`, 56pt height — z-conflict with new bottom bar

### Critical Detox testIDs (verified in code)
- `reader-epub` at `[id].tsx:623`, `reader-position-indicator` at `:631`
- `pdf-reader` at `pdf/[id].tsx:448`, `reader-toggle-toolbar` at `:479`, `reader-next-page-btn` at `:558`
- `mobi-reader` at `mobi/[id].tsx:442`, `reader-toggle-toolbar` at `:474`, `reader-next-page-btn` at `:601`
- `djvu-reader` at `djvu/[id].tsx:366`, `reader-next-page-btn` at `:539`
- `search-input` at `SearchPanel.tsx:91`, `search-no-results` at `:155`, `search-prompt` at `:161`
- `bookmarks-empty` at `BookmarksList.tsx:59`, `bookmark-row-${id}` at `:101`

---

## Architecture Decision

**ReaderShell owns state; format screens are thin content wrappers.**

- ReaderShell `useState` for `toolbarVisible`, all 6 sheet-open booleans
- `ReaderShellContext` exposes `bottomBarVisible` and `toggleToolbar` — consumed by TTSControls (z-fix) and EPUB's `onSingleTap`
- `centerOverride?: ReactNode` on `ReaderBottomBar` for PDF/MOBI/DJVU nav clusters
- Font size stays in `%` (80-150), no migration (resolves R7)
- `theme: ReaderTheme` removed from all 6 sheets; sheets use `useTheme()`
- `READER_THEMES` stays alive for epubjs `changeTheme()`

---

## Section 1: New files in `apps/mobile/components/reader/`

### `ReaderShell.tsx`

```ts
export type ReaderFormat = 'epub' | 'pdf' | 'mobi' | 'djvu'

export type ReaderProgress =
  | { kind: 'page';    current: number; total: number }
  | { kind: 'chapter'; current: number; total: number }
  | { kind: 'cfi';     label: string }
  | { kind: 'none' }

export interface ReaderShellSheets {
  toc?: boolean; highlights?: boolean; bookmarks?: boolean
  search?: boolean; appearance?: boolean; noteEditor?: boolean
}

export const ReaderShellContext = React.createContext<{
  bottomBarVisible: boolean
  toggleToolbar: () => void
}>({ bottomBarVisible: false, toggleToolbar: () => {} })

export interface ReaderShellProps {
  title: string
  format: ReaderFormat
  children: ReactNode
  onBack: () => void
  progress: ReaderProgress
  initialToolbarVisible?: boolean  // default: false
  ttsActive?: boolean
  realtimeActive?: boolean
  centerOverride?: ReactNode
  
  // Action cluster (undefined = button not rendered)
  onBookmarkTogglePress?: () => void
  isBookmarked?: boolean
  onTTSPress?: () => void
  ttsButtonActive?: boolean
  onRealtimePress?: () => void
  realtimeStatus?: RealtimeStatus
  onChatPress?: () => void
  
  sheets?: ReaderShellSheets
  
  // TOC
  toc?: TocItem[]
  currentHref?: string | null
  onSelectChapter?: (href: string) => void
  
  // Highlights
  highlights?: Highlight[]
  onNavigateToHighlight?: (cfiRange: string) => void
  onDeleteHighlight?: (id: string) => void
  
  // Bookmarks
  bookmarks?: Bookmark[]
  onNavigateToBookmark?: (location: string) => void
  onDeleteBookmark?: (id: string) => void
  
  // Search
  searchQuery?: string
  searchResults?: SearchResult[]
  isSearching?: boolean
  onChangeSearchQuery?: (q: string) => void
  onSelectSearchResult?: (cfi: string) => void
  onSearchSheetClose?: () => void
  
  // Appearance
  settings?: ReaderSettings
  onSettingsChange?: (next: ReaderSettings) => void
  
  // NoteEditor (controlled)
  noteEditorHighlight?: NoteEditableHighlight | null
  noteEditorOpen?: boolean  // controlled by parent
  onSaveNote?: (highlightId: string, note: string) => void
  onDiscardNote?: () => void
  
  testID?: string
}
```

Internal state: `toolbarVisible`, `tocOpen`, `highlightsOpen`, `bookmarksOpen`, `searchOpen`, `appearanceOpen`, `noteEditorOpen` — all via `useState`.

Auto-hide useEffect: 3s timer cleared when `ttsActive || realtimeActive`.

NoteEditor controlled bridge: sync local `noteEditorOpen` with `props.noteEditorOpen` via useEffect.

### `ReaderTopBar.tsx`
```ts
export interface ReaderTopBarProps {
  visible: boolean
  title: string
  onBack: () => void
  testID?: string
}
```
Reanimated fade 200ms via `withTiming`. `<Toolbar position="top" blur transparent hairline>`. zIndex 10.

### `ReaderBottomBar.tsx`
```ts
export interface ReaderBottomBarProps {
  visible: boolean
  progress: ReaderProgress
  centerOverride?: ReactNode
  onTocPress?: () => void
  onHighlightsPress?: () => void
  onBookmarksPress?: () => void
  onSearchPress?: () => void
  onAppearancePress?: () => void
  onBookmarkTogglePress?: () => void
  isBookmarked?: boolean
  onTTSPress?: () => void
  ttsButtonActive?: boolean
  onRealtimePress?: () => void
  realtimeStatus?: RealtimeStatus
  onChatPress?: () => void
  testID?: string
}
```
Layout: `<Toolbar position="bottom" blur transparent hairline>`. Left=chapter label. Center=`centerOverride ?? <ReaderProgressPill>`. Right=IconButton cluster (only render when handler defined).

Ionicons mapping:
- TOC: `list-outline`
- Highlights: `pencil-outline`
- Bookmarks: `list-circle-outline`
- Appearance: `text-outline`
- Search: `search-outline`
- Bookmark toggle: `bookmark` / `bookmark-fill`
- TTS: `volume-high-outline`
- Realtime: `mic-outline`
- Chat: `chatbubble-outline`

IconButton: `size={20}`, `hitSlop={10}`.

### `ReaderProgressPill.tsx`
```ts
export interface ReaderProgressPillProps {
  progress: ReaderProgress
  testID?: string
}
```
View with `colors.fill.tertiary` bg, `radius.full`, `spacing.xxs/md` padding. Text in caption typography, `colors.label.secondary`.

Labels: `page` → `"${c} / ${t}"`, `chapter` → `"Ch ${c}/${t}"`, `cfi` → `label`, `none` → `"—"`.

### `index.ts`
Barrel exports.

---

## Section 2: Refactored sheet APIs

All 6 sheets drop `sheetRef` and `theme`. New props:

```ts
// AppearanceSheet
{ isOpen, onClose, settings, onSettingsChange, format }

// TocSheet
{ isOpen, onClose, toc, currentHref, onSelectChapter }

// HighlightsSheet
{ isOpen, onClose, highlights, onNavigate, onDelete }

// BookmarksList
{ isOpen, onClose, bookmarks, onNavigate, onDelete }

// SearchPanel
{ isOpen, onClose, query, results, isSearching, onChangeQuery, onSelectResult }

// NoteEditor
{ isOpen, onClose, highlight, onSave, onDiscard }
```

Each uses `<Sheet>` primitive with appropriate `snapPoints` and `useTheme()` for colors.

### Sheet implementations

**AppearanceSheet**: `snapPoints={['45%']}`, doesn't close on changes. SegmentedControl for font family (EPUB only). 3 theme tiles (white/sepia/dark) as PressableScale circles with `colors.reader.paper*`.

**TocSheet**: `snapPoints={['75%']}`, scrollable. ListRow with `accessory='check'` on current chapter. EmptyState "No Table of Contents".

**HighlightsSheet**: `snapPoints={['75%']}`. ListRow with color dot + text + trailing trash IconButton. Replaces Alert-on-long-press. EmptyState.

**BookmarksList**: `snapPoints={['75%']}`. Explicit `testID="bookmark-row-${id}"` View wrapping ListRow. `testID="bookmarks-empty"` on EmptyState wrapper.

**SearchPanel**: `snapPoints={['95%']}`, showGrabber. `<SearchBar>` with `textInputTestID="search-input"`. Preserve `testID="search-no-results"`, `search-prompt`.

**NoteEditor**: `snapPoints={[320]}`, `keyboardBehavior="interactive"`. Add `testID="note-editor-input/save/discard"`.

---

## Section 3: Per-format screen changes

### `app/reader/[id].tsx` (EPUB+AZW3)

**Remove**:
- 6 `useRef<BottomSheet>` at lines 117-122
- `import BottomSheet` at line 7
- `import { ReaderToolbar }` at line 21 + JSX at 652-688
- `toolbarVisible` useState at 125
- Auto-hide useEffect at 277-285
- All `sheetRef.current?.snapToIndex(0)` calls
- All `theme={theme}` props on sheet components
- 6 sheet JSX blocks

**Keep**: useReader, usePlayerMachine, useTtsChatBridge, useRealtimeChat, useRequireAuth, usePageCaptureRef, useUndoSnackbar, CFI tracking, handleLocationChange, all handlers, menuItems, AnnotationPopover, GuardrailWarning, TTSControls, TTSVisualCue, UndoSnackbar. `testID="reader-epub"` and `reader-position-indicator` unchanged.

**Add**:
- `useContext(ReaderShellContext).toggleToolbar` for onSingleTap
- `const [noteEditorOpen, setNoteEditorOpen] = useState(false)`
- `progressForShell` derived from `toc + currentHref`
- `<ReaderShell>` JSX with full prop set
- Combined `onSettingsChange` handler

Diff estimate: -180 +60 lines net.

### `app/reader/pdf/[id].tsx`

**Remove**: inline top bar (492-532), bottom bar (534-566), `toolbarVisible` useState (95), inline `Pressable` toggle (479).

**Keep**: PdfWebReader, pdfStore subscriptions, outline Modal, GoToPageModal, ThumbnailModal, selection action bar, highlight picker bar, TTSControls, TTSVisualCue, UndoSnackbar, NoteEditor (new isOpen API). `testID="pdf-reader"`, `reader-position-indicator` unchanged.

**Add**:
- `<ReaderShell initialToolbarVisible={true}>` with PDF-specific props
- `PressableToggleToolbar` (uses context, preserves `testID="reader-toggle-toolbar"`)
- `PdfNavCluster` local: prev-chevron + page indicator + next-chevron with `testID="reader-next-page-btn"`
- `noteEditorOpen` useState; `setTimeout(() => setNoteEditorOpen(true), 100)` replaces the old setTimeout pattern at line 351

Diff: -80 +40.

### `app/reader/mobi/[id].tsx`

**Remove**: top bar (487-549), bottom bar (552-614), `toolbarVisible` useState (218), auto-hide useEffect (292-300) — R3 fix.

**Add**:
- `<ReaderShell sheets={{}}>` (no TOC/Appearance — defer to Phase 5)
- `realtimeActive={realtimeStatus !== 'idle'}` — R3 fix
- `PressableToggleToolbar`
- `MobiNavCluster`: prev/next chevrons + `"Ch ${n}/${total}"` text with `reader-next-page-btn`

Diff: -130 +40.

### `app/reader/djvu/[id].tsx`

Same pattern as MOBI.

**Add**:
- `<ReaderShell sheets={{}}>` 
- `PressableToggleToolbar` (NEW testID for DJVU — currently missing)
- `DjvuNavCluster`: zoom-out + zoom% + zoom-in + prev + page + next with `reader-next-page-btn`

Diff: -120 +40.

---

## Section 4: Deleted files

`apps/mobile/components/ReaderToolbar.tsx` — Stage G. Verify with:
```bash
grep -r "ReaderToolbar" apps/mobile --include="*.tsx" --include="*.ts"
```

---

## Section 5: TTSControls z-index fix

`apps/mobile/components/TTSControls.tsx`:
```ts
import { useContext } from 'react'
import { ReaderShellContext } from '@/components/reader/ReaderShell'

const BOTTOM_BAR_HEIGHT = 44

// inside component:
const { bottomBarVisible } = useContext(ReaderShellContext)

// replace line 64:
bottom: insets.bottom + 16 + (bottomBarVisible ? BOTTOM_BAR_HEIGHT : 0)
```

Outside reader screens, context defaults to `{ bottomBarVisible: false }` — safe.

---

## Section 6: Token mapping

| Old | New |
|---|---|
| `theme.background` | `colors.background.secondary` |
| `theme.color` | `colors.label.primary` |
| `theme.toolbarBg` | DELETED (use Toolbar blur) |
| `theme.toolbarText` | DELETED |
| `#0a7ea4` | `colors.accent.primary` |
| `#687076` | `colors.label.secondary` |
| `#9CA3AF` | `colors.label.tertiary` |

`AnnotationPopover`: internal color usage updated to `useTheme()`. The `theme: ReaderTheme` prop stays (deprecated) — full removal in Phase 6.

---

## Section 7: Test surface

### New tests (red phase)

**`__tests__/components/reader/ReaderShell.test.tsx`**:
1. Toolbar hidden on initial render
2. `toggleToolbar` via context shows toolbar
3. Auto-hide fires after 3000ms
4. Auto-hide paused when `ttsActive`
5. Auto-hide paused when `realtimeActive`
6. TOC sheet opens on onTocPress
7. `bottomBarVisible` context value matches `toolbarVisible`
8. `initialToolbarVisible={true}` starts visible

Mock strategy: mock ReaderTopBar/ReaderBottomBar as View wrappers. Mock sheets as `({isOpen}) => isOpen ? <View testID="sheet-open"/> : null`.

**`__tests__/components/reader/ReaderProgressPill.test.tsx`**:
4 tests covering each progress kind.

### Existing sheet tests
Run `grep -r "sheetRef|theme.*ReaderTheme" apps/mobile/__tests__` to find tests needing update.

### E2E (Detox)
`e2e/reader-epub.test.ts` — no changes needed (only uses `reader-epub` testID).

---

## Section 8: Build order

```
Stage A: ReaderShell + sub-components (tests red, then green)
  Files: ReaderShell, ReaderTopBar, ReaderBottomBar, ReaderProgressPill, index
  Commit: feat(mobile/reader): ReaderShell with new toolbar layout

Stage B: Sheet refactor (backward-compat shim during transition)
  Files: AppearanceSheet, TocSheet, HighlightsSheet, BookmarksList, SearchPanel, NoteEditor, AnnotationPopover (light)
  Strategy: accept both APIs temporarily; new {isOpen, onClose} preferred, old {sheetRef, theme} no-op deprecated
  Commit: refactor(mobile): reader sheets use Sheet primitive + design tokens

Stage C: EPUB reader → ReaderShell
  Commit: feat(mobile): EPUB reader uses ReaderShell

Stage D: PDF reader → ReaderShell
  Commit: feat(mobile): PDF reader uses ReaderShell

Stage E: MOBI reader → ReaderShell (+ R3 fix)
  Commit: feat(mobile): MOBI reader uses ReaderShell

Stage F: DJVU reader → ReaderShell (+ R3 fix)
  Commit: feat(mobile): DJVU reader uses ReaderShell

Stage G: Delete ReaderToolbar
  Verify grep returns zero
  Commit: refactor(mobile): delete deprecated ReaderToolbar

Stage H: TTSControls z-index fix
  Commit: fix(mobile): TTSControls clears bottom toolbar
```

Each stage gates on: jest green + typecheck clean.

---

## Section 9: Risks verified

- **R1** Detox testIDs — MANAGED. All 13 critical IDs preserved with documented locations.
- **R2** TTSControls z-conflict — SOLVED via Section 5.
- **R3** MOBI/DJVU TTS-awareness — FIXED. Per-screen timers deleted; ReaderShell centralizes with realtimeActive prop.
- **R4** Theme coupling — Stage B shim handles transition.
- **R5** PDF "always visible" — `initialToolbarVisible={true}`.
- **R6** MOBI/DJVU TOC — DEFERRED to Phase 5; `sheets={{}}`.
- **R7** Font size scale — RESOLVED by keeping `%` storage.

---

## Section 10: Done-when

1. All 4 reader screens use `<ReaderShell>` with glass-blur top + bottom toolbars
2. All 6 sheets use `Sheet` primitive + `useTheme()`; no sheetRef, no theme prop
3. `ReaderToolbar.tsx` deleted; grep returns zero
4. Detox e2e tests pass (or skipped with reason)
5. `pnpm typecheck` clean
6. `pnpm test` ≥606 jest passing (no regression)
7. Simulator screenshot: TTSControls clears bottom toolbar
8. All critical testIDs accessible to Detox
