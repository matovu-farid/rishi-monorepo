# Phase 3 — Reader UI Redesign: RESEARCH.md

Date: 2026-05-22
Author: researcher agent

---

## 1. Current mobile reader state per format

| Format | Chrome layout | Sheets present | Tap-to-toggle | Progress indicator | Gesture |
|---|---|---|---|---|---|
| **EPUB** (`app/reader/[id].tsx`) | Single top bar (`ReaderToolbar`), 48pt + insets.top. All actions in top bar. | TOC, Bookmarks, Highlights, Search, Appearance, NoteEditor (6 sheets) | `onSingleTap` from `@epubjs-react-native/core`. Auto-hide 3s (paused for TTS/voice). | Hidden `reader-position-indicator` (Detox only) | `flow="paginated"`, swipe via epubjs-react-native |
| **PDF** (`app/reader/pdf/[id].tsx`) | Top + bottom bars, `rgba(0,0,0,0.7)`, dark always | NoteEditor as `BottomSheet`; TOC as `<Modal>` | `reader-toggle-toolbar` 48pt strip at top. No auto-hide. Starts visible. | Bottom: `{pageNumber}/{pageCount}` 16pt white | Continuous scroll via PdfWebReader |
| **MOBI** (`app/reader/mobi/[id].tsx`) | Top + bottom bars, `rgba(0,0,0,0.7)` | None | 60% width × 40% height center tap target. Auto-hide 3s (unconditional). | Top right: `Ch {n}/{total}` 13pt. Bottom: `{ch+1}/{total}` 16pt. | Chapter prev/next buttons |
| **DJVU** (`app/reader/djvu/[id].tsx`) | Top + bottom bars, `rgba(0,0,0,0.8)` | None | Same 60×40 center tap. Auto-hide 3s. | Top right: `Page {n}/{total}`. Bottom: `{p}/{total}`. | Page prev/next + zoom controls |
| **AZW3** | Routes to `app/reader/[id].tsx` (EPUB) — confirmed via `book-storage.ts:82` collapse + `(tabs)/index.tsx` routing fallthrough | Same as EPUB | Same as EPUB | Same as EPUB | Same as EPUB |

### Key asymmetries
- EPUB has 6 sheets; PDF has 1 (NoteEditor); MOBI/DJVU have 0
- Only EPUB has theme-aware chrome via `ReaderTheme`
- Only EPUB pauses auto-hide during TTS/voice
- PDF starts with toolbar visible; others start hidden
- Progress format differs per format (none / page / chapter / page+zoom)

---

## 2. Reader chrome components

### 2.1 `ReaderToolbar.tsx`
Single Reanimated `Animated.View`, `FadeIn`/`FadeOut` 200ms. Absolutely positioned top:0, 48pt. Theme-aware via `ReaderTheme`. NativeWind `className` + inline styles. No `testID` on buttons.

**Phase 3:** delete; replace with `ReaderShell` + Phase 2 `Toolbar`.

### 2.2 `AppearanceSheet.tsx`
`BottomSheet` `snapPoints={[280]}`. Background = `theme.background`. Font size in % (80-150 step 10). 3 theme swatches. Hardcoded `#0a7ea4`.

**Phase 3:** `Sheet` primitive, `SegmentedControl` for font picker, design tokens, 4-tile theme (light/sepia/gray/dark).

### 2.3 `TocSheet.tsx`
`BottomSheet` `snapPoints={['50%','90%']}` + `BottomSheetFlatList`. Current chapter: `borderLeftColor:'#0a7ea4'`. `theme.background`.

**Phase 3:** `Sheet` + `ListRow` rows + `accessory='chevron'` + `check` on active. Tabs (Contents/Bookmarks) via `SegmentedControl` if cheap.

### 2.4 `HighlightsSheet.tsx`
`BottomSheet` `snapPoints={['50%','90%']}`. Long-press → Alert for delete. 10x10 color dot. Italic note preview.

**Phase 3:** `Sheet` + `ListRow` + swipe-to-delete (replace long-press). Color filter chips at top.

### 2.5 `BookmarksList.tsx`
`BottomSheet` `snapPoints={['50%','90%']}`. Has `testID="bookmark-row-${id}"` and `testID="bookmarks-empty"` — preserve.

**Phase 3:** `Sheet` + `ListRow` + trailing trash IconButton.

### 2.6 `SearchPanel.tsx`
`BottomSheet`. `testID="search-input"`, `search-no-results`, `search-prompt`. Inline search input. Hardcoded bg `#374151`/`#F3F4F6`.

**Phase 3:** `Sheet` + `SearchBar` primitive. Preserve testIDs.

### 2.7 `NoteEditor.tsx`
Exports `NoteEditableHighlight` (shared EPUB+PDF type). `BottomSheet` `snapPoints={[320]}` with `keyboardBehavior="interactive"`. Hardcoded colors.

**Phase 3:** `Sheet` + design tokens. Add testIDs.

### 2.8 `TTSControls.tsx`
Floating bar `bottom: insets.bottom + 16`, `rgba(0,0,0,0.8)`. Format-agnostic. `SlideInDown.duration(250)`.

**Phase 3:** minimal. Phase 4 redesigns as MiniPlayer. Just ensure z-index/spacing doesn't collide with new bottom toolbar.

### 2.9 `AnnotationPopover.tsx`
Absolute-positioned `Animated.View`. EPUB-only. `POPOVER_HEIGHT = 160` fragile.

**Phase 3:** light touch — use design tokens for bg/text, shadow.medium.

---

## 3. Reader settings sourcing

### Global (shared across books) — `lib/reader-settings.ts`
- Synchronous SQLite key-value
- Loaded on EPUB mount: `useState<ReaderSettings>(loadReaderSettings())`
- `themeName: 'white' | 'dark' | 'yellow'`
- `fontSize`: percentage int 80–150 step 10 (passed to `changeFontSize('${size}%')`)
- `fontFamily: 'serif' | 'sans-serif'` (EPUB only; MOBI hardcoded Georgia)

### Per-book — `books` table (Drizzle)
- `currentCfi` (EPUB/AZW3): 500ms debounce + on AppState background
- `currentPage` (PDF/MOBI/DJVU)

### READER_THEMES → token mapping for Phase 3
- `white.background` → `colors.reader.paperPureWhite`
- `yellow.background` → `colors.reader.paperSepia`
- `dark.background` → `colors.reader.paper` (dark mode)
- `toolbarBg` → DEPRECATED; toolbar uses `Toolbar blur=true` (system material)

---

## 4. Electron reader patterns (reference)

### EPUB chrome
- No persistent top nav (uses native window bar)
- Left-slide `ReaderTOC` with Contents/Bookmarks tabs
- Right-side ChatPanel
- Floating `AIChatOrb`+`VoiceChatLauncher`+`TTSControls`
- `NavigationHistoryFooter` for progress

### Translation to mobile

| Electron | Mobile equivalent |
|---|---|
| Native window back | `IconButton chevron.left` in top Toolbar |
| Left-slide TOC drawer | Bottom Sheet + SegmentedControl tabs |
| Right-side chat | Bottom Sheet OR separate screen (defer chat-panel-on-reader) |
| Tailwind `backdrop-blur-sm bg-white/80` | `Toolbar blur=true` + `expo-blur intensity=80` |
| NavigationHistoryFooter | Progress pill in bottom Toolbar center |

---

## 5. Apple Books reference (concrete values)

### Top bar
- 44pt + insets.top
- Invisible until tap; fade in 150ms (`timing.fast`)
- Back chevron (left, 22pt), title (center, 17pt semibold), no right slot
- Glass: `expo-blur intensity=80 tint=systemUltraThinMaterialLight`

### Bottom bar
- 44pt + insets.bottom; same blur
- Left: chapter title (14pt label.secondary)
- Center: progress pill — radius.full, fill.tertiary, footnote 13pt, padding xs/md
- Right: 3-5 IconButtons (TOC, Aa, Search, bookmark, highlights)
- Both bars animate together as one unit

### Tap-to-toggle
- Single tap on content toggles both bars together
- Apple has no auto-hide; we keep our 3s timer paused for TTS/voice

### Sheets
- TOC: 75% sheet, SegmentedControl tabs
- Appearance: 45% sheet, brightness/Aa-/Aa+/font picker/4 theme tiles
- Search: 95% sheet, SearchBar autofocus
- Highlights: 75% sheet, color filter chips, swipe-to-delete
- Sheet does NOT close on settings change (stays open for rapid iteration)

### Page turn
- Continuous scroll default (Apple); paginated option
- Phase 3 keeps existing `flow="paginated"` enableSwipe (no engine change)

---

## 6. Refactor target

### New files
```
apps/mobile/components/reader/
  ReaderShell.tsx         — owns top/bottom Toolbar + all sheet mounts
  ReaderTopBar.tsx        — back + title
  ReaderBottomBar.tsx     — chapter + progress + action cluster
  ReaderProgressPill.tsx  — "Page X of Y" pill
```

### Migrated files
- `AppearanceSheet`, `TocSheet`, `HighlightsSheet`, `BookmarksList`, `SearchPanel`, `NoteEditor` — refactor to use `Sheet` primitive + tokens
- `ReaderToolbar` — DELETE
- `AnnotationPopover` — light touch (tokens only)
- `TTSControls` — z-index fix only

### Thin reader screens
- `app/reader/[id].tsx` — delegates to `<EpubContent>` + `<ReaderShell>` mount
- `app/reader/pdf/[id].tsx` — `<PdfWebReader>` + `<ReaderShell>`
- `app/reader/mobi/[id].tsx`, `djvu/[id].tsx` — `<WebView>` + `<ReaderShell>`

### ReaderShell ownership decision
**Recommendation:** ReaderShell owns sheet open/close booleans via `useState`. Format screens pass `onTocPress` etc; ReaderShell renders `<Sheet isOpen={tocOpen} ...>`. Eliminates 6 `useRef<BottomSheet>` patterns across format screens.

---

## 7. Risks

### R1 — Detox testID preservation
Critical IDs to preserve: `reader-epub`, `pdf-reader`, `mobi-reader`, `djvu-reader`, `reader-loading`, `reader-toggle-toolbar`, `reader-next-page-btn`, `reader-position-indicator`, `search-input`, `search-no-results`, `search-prompt`, `bookmarks-empty`, `bookmark-row-${id}`.

### R2 — Bottom toolbar + TTSControls z-order
TTSControls at `bottom: insets.bottom+16`. New bottom Toolbar at `bottom:0` with safe-area padding. When both visible: TTSControls must raise above Toolbar OR merge.

### R3 — MOBI/DJVU lose TTS-awareness
Their auto-hide doesn't check `ttsActive`. ReaderShell must centralize and apply EPUB's "extend timer when TTS active" to all formats.

### R4 — Theme coupling in sheets
All 6 sheets currently take `theme: ReaderTheme` and use it for own bg. Phase 3 decouples: sheets use `colors.background.secondary` always. Risk: Detox screenshot/color assertions.

### R5 — PDF "always visible" toolbar default
PDF starts `toolbarVisible=true`. Apple Books starts hidden. ReaderShell normalizes: visible 2s on first open then fade. Detox tests may need update.

### R6 — MOBI/DJVU TOC infrastructure
MOBI/DJVU emit chapter index but not titles. Adding TOC sheet to MOBI/DJVU requires WebView change. **Decision: Phase 3 ships chrome to MOBI/DJVU but defers TOC/Appearance sheets to Phase 5.**

### R7 — Font size scale mismatch
`fontSize` stored as % (80-150). UI-SPEC wants pt (14-22). Architect decides: keep % display, or convert pt→% internally.

---

## 8. Essential files reference

### Reader screens
- `apps/mobile/app/reader/[id].tsx` (EPUB+AZW3, full chrome)
- `apps/mobile/app/reader/pdf/[id].tsx`
- `apps/mobile/app/reader/mobi/[id].tsx`
- `apps/mobile/app/reader/djvu/[id].tsx`

### Existing chrome (to refactor)
- `apps/mobile/components/ReaderToolbar.tsx` (DELETE)
- `apps/mobile/components/AppearanceSheet.tsx`
- `apps/mobile/components/TocSheet.tsx`
- `apps/mobile/components/HighlightsSheet.tsx`
- `apps/mobile/components/epub/BookmarksList.tsx`
- `apps/mobile/components/epub/SearchPanel.tsx`
- `apps/mobile/components/NoteEditor.tsx`
- `apps/mobile/components/AnnotationPopover.tsx`
- `apps/mobile/components/TTSControls.tsx` (touch only)

### Phase 2 primitives (consume)
- `apps/mobile/components/ui/{Sheet,Toolbar,IconButton,SegmentedControl,SearchBar,ListRow,EmptyState,Hairline,index}.tsx`

### Theme / settings
- `apps/mobile/lib/theme/useTheme.ts`, `tokens.ts`, `colors.ts`, `typography.ts`
- `apps/mobile/lib/reader-settings.ts`
- `apps/mobile/constants/reader-themes.ts`
- `apps/mobile/types/book.ts`

### Routing
- `apps/mobile/app/(tabs)/index.tsx` (handleBookPress)
- `apps/mobile/lib/book-storage.ts` (AZW3→mobi at :82)

### Electron reference (read-only)
- `apps/rishi-electron/src/renderer/src/components/reader/ReaderTOC.tsx`
- `apps/rishi-electron/src/renderer/src/components/reader/ReaderOverlayControls.tsx`
- `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`
