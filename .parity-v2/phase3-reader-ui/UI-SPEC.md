# Phase 3 — Reader UI Redesign (UI-SPEC)

Date: 2026-05-22
Status: Designer spec — input for the architect's file plan
Scope: Reader chrome (top + bottom toolbars), sheets, motion, haptics, per-format adaptations. Consumes Phase 2 tokens + primitives.

Design philosophy: Apple Books on iPhone. Minimal, premium, restrained. Glass-blur chrome that disappears on tap. Generous whitespace. System fonts (SF for chrome, New York / `ui-serif` for book body). Quiet, soft haptics. Sheets for everything secondary — never modals, never drawers.

Token references throughout this spec use the Phase 2 contract:
`colors.*`, `spacing.*`, `radius.*`, `motion.*`, `shadow.*`, `typography.scale.*` — all from `@/lib/theme` (`apps/mobile/lib/theme/`).

---

## 1. ReaderShell layout

`<ReaderShell>` is the single chrome host for all formats. It owns the top toolbar, bottom toolbar, the sheet mount points, the chrome visibility state, the auto-hide timer, and the fade animation. Format screens (EPUB / PDF / MOBI / DJVU) render their engine as `children` and supply props.

### 1.1 Chrome hidden (default)

```
┌─────────────────────────────────────────────┐
│ (status bar, content shows through)         │  ← safe-area top, no chrome
│                                             │
│                                             │
│                                             │
│                                             │
│                                             │
│              Book content                   │  ← engine renders here
│              (full-bleed)                   │     children of ReaderShell
│                                             │
│                                             │
│                                             │
│                                             │
│                                             │
│                                             │  ← safe-area bottom, no chrome
└─────────────────────────────────────────────┘

Single tap anywhere on content → toggles chrome (Section 5: motion).
The reader engine handles its own swipe / scroll gestures unchanged.
```

### 1.2 Chrome visible

```
┌─────────────────────────────────────────────┐
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│  ← BlurView, intensity 80
│░░ <  Title of the Book                   ░░░│     systemUltraThinMaterial*
│░ ──────────────────────────────────────── ░│  ← hairline (separator.nonOpaque)
│                                             │
│              Book content                   │
│                                             │
│  (engine continues to render full-bleed —   │
│   chrome is overlaid, not pushing content)  │
│                                             │
│ ──────────────────────────────────────────  │  ← hairline above bottom bar
│░ Chapter title    ⌒13 min left⌒  ▤ Aa ⚐ ⌕░ │  ← bottom toolbar, blur
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
└─────────────────────────────────────────────┘

Top toolbar (44pt + safeAreaInsets.top):
  Left:    [<]  IconButton name="chevron.back", 22pt, accent.primary
  Center:  Book title — typography.scale.body (17pt) semibold,
           1-line truncate, label.primary
  Right:   empty (designer call: chrome stays minimal; settings live in
           bottom-right cluster as "Aa", not as a top-bar gear icon)

Bottom toolbar (44pt + safeAreaInsets.bottom):
  Left:    Chapter title — typography.scale.subhead (15pt)
           regular, label.secondary, truncate to ~40% width
  Center:  Progress pill — ReaderProgressPill (Section 1.3)
  Right:   Action cluster — 4 IconButtons spaced spacing.md apart:
           [ list.bullet ]  [ textformat ]  [ bookmark ]  [ magnifyingglass ]
              TOC              Aa              bookmark      search

Order rationale (left-to-right): TOC, Aa, bookmark, search.
Highlights is INTENTIONALLY collapsed into the TOC sheet as a tab
(Section 3.1) — five icons in the right cluster is too many for an
iPhone width. This matches Apple Books on iPad (Contents/Bookmarks
tabs) and keeps a tidy 4-button cluster on iPhone.
```

### 1.3 Progress pill (`ReaderProgressPill`)

```
   ╭───────────────────╮
   │  13 min left      │
   ╰───────────────────╯

   Background: colors.fill.tertiary
   Radius:     radius.full
   Padding:    vertical spacing.xs (4pt), horizontal spacing.md (12pt)
   Text:       typography.scale.footnote (13pt), label.secondary
   Height:     ~26pt (footnote 13pt + 8pt padding + 5pt lineHeight slack)
```

The pill is tappable (forwards a `onProgressPress?` callback) — Phase 3
leaves it inert by default; PDF screens can use it to open the
GoToPage modal. Tap target inflates via PressableScale + hitSlop 8.

### 1.4 Chrome show/hide animation

- Both bars (top + bottom) animate **together as one unit**, never separately.
- Property: opacity `0 → 1` (in) or `1 → 0` (out). **No slide.**
- Duration: `motion.timing.fast` (200ms; treat 150ms target as "fast" with the existing token — do not introduce a new token).
- Easing: `motion.timing.fast.easing` (out-quad).
- During the fade, both bars are mounted (so they stay in the VoiceOver tree); when fully hidden, `pointerEvents='none'` blocks taps from leaking into the engine.
- Reduce motion: opacity transition replaced by instant swap (0ms).

### 1.5 Auto-hide timer

- 3s after the last interaction with chrome (tap, button press inside toolbar).
- **Paused** while TTS playback is active (`playerStore.playingState !== 'idle'`) OR realtime voice chat is active (`realtimeStatus !== 'idle'`).
- **Paused** while any sheet is open.
- Re-arms on every chrome-toggle-to-visible event. If the user re-taps to hide manually, the timer is cancelled (the chrome is already gone).

This is the EPUB-existing behavior generalized; MOBI/DJVU currently lack the TTS guard (R3 in research) — ReaderShell fixes this for all formats.

### 1.6 Tap-to-toggle target

ReaderShell mounts an invisible `<Pressable testID="reader-toggle-toolbar">` covering the full content area (under all other floating chrome). It calls `onContentTap()` which flips `chromeVisible`.

EPUB: the existing `onSingleTap` from `@epubjs-react-native/core` continues to be the source of truth — ReaderShell exposes a `setChromeVisible` imperative handle so the EPUB screen can forward `onSingleTap` to it. The pressable is **not** mounted for EPUB (the engine owns taps).

PDF / MOBI / DJVU: ReaderShell mounts the full-area Pressable. The PDF screen MUST stop rendering its own 48pt top tap strip — ReaderShell now owns this gesture across the entire content area.

The `testID="reader-toggle-toolbar"` MUST be on the Pressable (or, for EPUB, on a 0×0 view that exposes `accessibilityActions={[{ name: 'activate' }]}`) — see Section 11.

---

## 2. Per-format adaptations

Every format passes a `ReaderShellProps` object to `<ReaderShell>`. Format-specific behavior is encoded in which sheets are mounted + which actions the right cluster offers.

### 2.1 EPUB / AZW3

Full Apple Books experience.

```ts
<ReaderShell
  testID="reader-epub"           // or "reader-azw3" — see Section 11
  title={book.title}
  chapterTitle={currentHref}     // resolved to spine display name where possible
  progress={{
    kind: 'epub',
    label: minLeft != null ? `${minLeft} min left` : `${percent}%`,
  }}
  actions={['toc', 'aa', 'bookmark', 'search']}
  // Sheet handlers
  onBack={handleBack}
  onTocPress={openTocSheet}
  onAppearancePress={openAppearanceSheet}
  onBookmarkTogglePress={handleToggleBookmark}
  onSearchPress={openSearchSheet}
  // Bookmark state (for filled/outline icon)
  isBookmarked={isCurrentBookmarked}
  // Sheets mounted as children-of-shell — see Section 1
  sheets={{
    toc: true,
    bookmarks: true,
    highlights: true,
    search: true,
    appearance: true,
    noteEditor: true,
  }}
  ttsActive={ttsActive}
  realtimeActive={realtimeActive}
>
  <Reader ... />
</ReaderShell>
```

Right cluster: **TOC, Aa, bookmark, search**. (Highlights lives inside the TOC sheet as a tab — Section 3.1.)

Progress: prefer "13 min left" when the engine reports `locations.total` and reading-rate (WPM 250 baseline). Fall back to "23%" of book completion. If neither is available, hide the pill (the bar still shows chapter title + actions).

Chapter title: spine entry display name. Resolve via `toc.find(t => t.href === currentHref)?.label`. Truncate at ~24 chars.

### 2.2 PDF

```
Right cluster: [ list.bullet ]  [ textformat ]  [ bookmark ]  [ magnifyingglass ]
                  TOC              Aa (limited)    bookmark      search (disabled)

Notes:
- TOC: existing PdfOutline migrates to the new TOC sheet (Section 3.1).
  Replace the current <Modal presentationStyle="formSheet"> with Sheet.
- Aa: opens AppearanceSheet, but with font picker HIDDEN and theme
  swatches HIDDEN. Only brightness (if Phase 3 lands it) + the Aa+/Aa-
  buttons remain — and even those are no-ops on PDF (PDFs are
  fixed-layout). Render the buttons disabled. Designer call: keep the
  Aa icon visible (for parity with EPUB position) but route it to a
  short sheet that says "Appearance is not available for PDF" with the
  brightness slider only. If Phase 3 doesn't ship brightness, HIDE the
  Aa icon entirely on PDF and reduce the cluster to 3 icons.
  Recommendation: HIDE Aa on PDF for Phase 3.
- Bookmark: tap toggles a per-book bookmark at the current page (new
  feature, parity with EPUB). Use existing bookmark-storage but key on
  page number (`location = 'page:42'`).
- Search: PDF search not implemented yet — render the search button
  DISABLED with the existing icon. Defer enabling to Phase 5.
  Recommendation: HIDE search on PDF for Phase 3.

Final PDF cluster: [ TOC ] [ bookmark ]
                    Two icons.  That's it.

Progress: pill shows "Page 42 of 310". Tap → opens the existing
GoToPage modal/Alert.prompt flow (Section 1.3 wires onProgressPress).
```

Chapter title in the bottom bar's left slot: PDF doesn't have chapters per se. Show the outline section name of the current page if the outline is available (walk `outline` for the nearest item with `pageNumber <= currentPage`). Otherwise show empty (allowing the pill to center cleanly).

**Drop the 48pt top tap strip.** Delete `testID="reader-toggle-toolbar"` Pressable inside `pdf/[id].tsx`. ReaderShell owns this now.

**Drop the "starts visible" default.** Phase 3 starts chrome hidden for parity with EPUB. After 2s of first mount, chrome briefly shows then auto-hides — this is the only first-open exception, and only on PDF (designer call: PDF users need to discover the toolbar; first-paint hint of 2s mitigates that). Detox tests may need adjustment (R5).

### 2.3 MOBI

```
Right cluster: [ Aa ] [ bookmark ]

Notes:
- TOC: NOT mounted in Phase 3 (R6: MOBI WebView emits chapter index but
  no titles). Defer to Phase 5. The TOC icon is HIDDEN from the cluster.
- Aa: opens AppearanceSheet. Font picker HIDDEN (MOBI engine doesn't
  expose font swapping). Theme swatches SHOWN (the WebView is themed
  via injected CSS). Font size buttons (Aa-/Aa+) SHOWN.
- Bookmark: SHOWN; toggles bookmark at current chapter index.
- Search: HIDDEN (not implemented).

Progress: pill shows "Ch 3 of 18" (use existing chapter index +
total chapter count).
```

Chapter title in the bottom bar's left slot: MOBI doesn't expose chapter titles — leave empty. The progress pill carries chapter info.

### 2.4 DJVU

```
Right cluster: [ Aa ] [ bookmark ] [ zoom.out ] [ zoom.in ]

Notes:
- TOC: NOT mounted in Phase 3 (same reason as MOBI).
- Aa: SHOWN, same constraints as MOBI (theme only).
- Bookmark: SHOWN; toggles at current page.
- Zoom: existing zoom controls move INTO the right cluster as two
  dedicated IconButtons (not a separate sheet). Rationale: DJVU users
  zoom frequently; burying behind a sheet adds friction. Apple Books
  uses pinch — DJVU WebView doesn't support pinch well yet, so the
  explicit buttons stay.

Progress: pill shows "Page 24 of 412".
```

Chapter title slot: empty.

Designer note: this format is the densest right cluster (4 icons). It's still 4 — same as EPUB. Buttons remain 22pt with 44pt hit targets via IconButton's default hitSlop=8.

### 2.5 Format props summary

| Format | TOC | Aa | Bookmark | Search | Zoom | testID |
|---|---|---|---|---|---|---|
| EPUB | yes | yes (full) | yes | yes | — | `reader-epub` |
| AZW3 | yes | yes (full) | yes | yes | — | `reader-epub` (same screen) |
| PDF | yes | hidden | yes | hidden | — | `pdf-reader` |
| MOBI | hidden | yes (theme+size) | yes | hidden | — | `mobi-reader` |
| DJVU | hidden | yes (theme+size) | yes | hidden | yes×2 | `djvu-reader` |

---

## 3. Refactored sheets

All sheets use the Phase 2 `Sheet` primitive. All take **system theme**, not reader theme (Section 4). All use `ListRow`, `SegmentedControl`, `SearchBar`, `EmptyState` where applicable.

### 3.1 TOC Sheet

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │  ← grabber (Sheet default)
│  Table of Contents                   │  ← optional title row (22pt semibold)
│                                      │
│  ┌─ Contents ─┬─ Bookmarks ─┐        │  ← SegmentedControl (size='md')
│  └────────────┴─────────────┘        │     value: 'contents' | 'bookmarks'
│                                      │
│  Chapter 1: Introduction       ✓     │  ← ListRow, accessory='check' active
│  Chapter 2: First Principles         │
│    Section 2.1                       │  ← depth=1, paddingLeft + 16
│    Section 2.2                       │
│  Chapter 3: ...                      │
│  ...                                 │
│                                      │
└──────────────────────────────────────┘

Sheet props:  snapPoints={['75%', '95%']}, default index 0
Background:   colors.background.secondary (system, not reader)
Body:         BottomSheetFlatList of ListRow

ListRow per TOC entry:
  - title:     entry label (17pt body, label.primary)
  - subtitle:  none
  - icon:      none
  - accessory: 'check' if entry.href === currentHref, else none
  - onPress:   handleSelectChapter(entry.href) → goToLocation + close
  - testID:    `toc-row-${index}`
  - indent:    paddingLeft = spacing.lg + (depth * 16)

Empty state (no toc):
  EmptyState
    icon="list.bullet"
    title="No contents"
    description="This book doesn't include a table of contents."
```

#### 3.1.1 Bookmarks tab

When `activeTab === 'bookmarks'`, the body switches to the bookmark list. **iPhone decision:** use the SegmentedControl tab pattern (matches Apple Books iPad). This consolidates the two sheets and frees a slot in the right cluster.

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │
│  Table of Contents                   │
│                                      │
│  ┌─ Contents ─┬─ Bookmarks ─┐        │
│  └────────────┴─────────────┘        │
│                                      │
│  ▮ Chapter 5: The Argument      🗑   │  ← ListRow, swatch left, trash right
│    May 21 · 13:42                    │
│  ▮ Chapter 8: Counterexamples   🗑   │
│    May 20 · 09:11                    │
│  ...                                 │
└──────────────────────────────────────┘

ListRow per bookmark:
  - icon:      <Ionicons name="bookmark" size={20} color={accent.error}/>
               (filled red bookmark — matches Apple Books)
  - title:     bookmark.label (chapter name or fallback to CFI prefix)
  - subtitle:  formatted timestamp ("May 21 · 13:42")
  - accessory: { kind: 'custom', node: <IconButton name="trash"
                  label={`Delete bookmark in ${title}`}
                  haptic="medium"
                  onPress={() => onDelete(bookmark.id)} /> }
  - onPress:   onNavigate(bookmark.location) → goToLocation + close sheet
  - testID:    `bookmark-row-${bookmark.id}`   ← PRESERVED

Empty state:
  EmptyState
    icon="bookmark"
    title="No bookmarks yet"
    description="Tap the bookmark icon on any page to save your place."
    testID="bookmarks-empty"   ← PRESERVED
```

Swipe-to-delete: **not** implemented in Phase 3. The trailing trash IconButton replaces the bad long-press UX and is sufficient. Long-press is removed. Swipe-to-delete is a Phase 6 polish if user testing demands it.

### 3.2 Highlights Sheet

Lives as a standalone sheet (NOT a tab inside TOC — too crowded for three tabs).

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │
│  Highlights                          │
│                                      │
│  ┌All┬Yellow┬Green┬Blue┬Pink┬Purple┐ │  ← horizontal color chips
│  └───┴──────┴─────┴────┴────┴──────┘ │     pills, footnote text
│                                      │
│  ■  "The whole of philosophy is..."  │  ← ListRow, color swatch left
│     Chapter 2 · May 18           🗑  │
│  ■  "Only those who attempt the..."  │
│     Chapter 5 · May 19           🗑  │
└──────────────────────────────────────┘

Sheet props:  snapPoints={['75%', '95%']}, default 0
Background:   colors.background.secondary

Color chips (top):
  Horizontal ScrollView. Each chip:
    - 28pt height
    - radius.full
    - bg: fill.tertiary (unselected), accent.primary (selected)
    - typography.scale.footnote (13pt), label.primary
    - selected: label.primary on accent.primary tint
    - haptic: 'selection' on tap
  Filter state held in sheet-local useState; default 'all'.

ListRow per highlight:
  - icon:      12pt square color swatch (colors.highlight[h.color])
               with separator.opaque border 0.5pt, radius.sm
  - title:     h.text — 2-line numberOfLines={2}, ellipsis tail
               (17pt body, label.primary)
  - subtitle:  `${chapter} · ${formattedDate}` (footnote, label.secondary)
  - accessory: { kind: 'custom', node: <IconButton name="trash"
                  label="Delete highlight"
                  haptic="medium"
                  onPress={() => onDeleteHighlight(h.id)} /> }
  - onPress:   onNavigateToHighlight(h.cfiRange) + close sheet
  - testID:    `highlight-row-${h.id}`

Empty state:
  EmptyState
    icon="highlighter"
    title="No highlights"
    description="Select text in the book and tap Highlight to save it here."
```

Long-press removed. Trash IconButton replaces it.

### 3.3 Search Sheet

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │
│  ╭───────────────────────────────╮   │  ← SearchBar primitive, autoFocus
│  │ 🔍  Search the book        ✕ │   │     testID="search-input"
│  ╰───────────────────────────────╯   │
│  ────────────────────────────────    │
│                                      │
│  ...and the proper study of mankind  │  ← ListRow
│  Chapter 4                           │
│  ────────────────────────────────    │
│  ...mankind has always asked         │
│  Chapter 9                           │
└──────────────────────────────────────┘

Sheet props:  snapPoints={['95%']} (search needs height for keyboard + results)
              keyboardBehavior="interactive"
Background:   colors.background.secondary

SearchBar at top of sheet:
  - autoFocus={true}
  - placeholder="Search the book"
  - onChange triggers debounced search (300ms)
  - testID="search-input"   ← PRESERVED on the inner TextInput

Body states:
  1. query.length === 0 → EmptyState
     icon="magnifyingglass"
     title="Search the book"
     description="Find words and phrases across all chapters."
     testID="search-prompt"   ← PRESERVED
  2. isSearching → centered <ActivityIndicator/> + "Searching…" caption
     testID="searching"
  3. query.length > 0 && results.length === 0 && !isSearching → EmptyState
     icon="magnifyingglass.circle"
     title="No matches"
     description={`No results for "${query}"`}
     testID="search-no-results"   ← PRESERVED
  4. results.length > 0 → BottomSheetFlatList of ListRow:
       - title: excerpt with the match (use the existing
                searchResults[i].excerpt; 2-line truncate)
       - subtitle: chapter name (footnote, label.secondary)
       - onPress: onSelectResult(cfi) + close sheet
       - testID: `search-result-${i}`

On sheet close (sheet index === -1): clear `searchQuery` + clear results
(preserves the existing "open fresh" behavior).
```

### 3.4 Appearance Sheet

Compact, ~50% detent. Designer's call: do NOT close on changes. Apple-Books-style live preview.

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │
│  Appearance                          │
│                                      │
│  ☀ ─────────────●──── ☀              │  ← Brightness slider (optional)
│                                      │
│  Aa  ━━━━━━━━━━━━━━━━━━━━━  Aa       │  ← Font-size row
│            Aa-     16pt     Aa+      │
│                                      │
│  ┌─ Serif ──┬── Sans ──┐             │  ← Font picker (EPUB only)
│  └──────────┴──────────┘             │     SegmentedControl size='md'
│                                      │
│      ⚪    🟡    ⚫    ⬛              │  ← Theme tiles (4×40pt circles)
│     light  sepia  gray  black        │
└──────────────────────────────────────┘

Sheet props:  snapPoints={['50%']}, no second detent
              animationConfigs: motion.spring.gentle
Background:   colors.background.secondary

Section 1 — Brightness slider (Phase 3 STRETCH):
  - Track: fill.tertiary, height 4pt, radius.full
  - Thumb: 24pt circle, background.primary, shadow.low
  - Tick icons at ends: Ionicons "sunny-outline" 16pt, label.tertiary
  - If `expo-brightness` is not installed by Phase 3 — OMIT this row.
    Recommendation: DEFER to Phase 6.

Section 2 — Font size row:
  Layout: [IconButton "Aa-"]  [centered text "16pt"]  [IconButton "Aa+"]
    - IconButtons: use Ionicons name "text" but render literal text "Aa-"
      / "Aa+" inside a 44×44 PressableScale. Background: fill.tertiary
      circle (radius.full), 44pt diameter. Label color label.primary.
    - Center text: typography.scale.body (17pt) semibold, label.primary.
      Width fixed 64pt so the buttons don't jump.
    - haptic: 'selection' on press
    - Disabled when at min (80% = 13pt) or max (150% = 24pt) — opacity 0.4,
      no haptic.

Section 3 — Font picker (EPUB / AZW3 ONLY):
  SegmentedControl options={[{label:'Serif', value:'serif'},
                              {label:'Sans', value:'sans-serif'}]}
  fullWidth={true}, size='md'
  HIDDEN on PDF (no effect), MOBI/DJVU (engines don't expose font swap)

Section 4 — Theme tiles:
  4 circular swatches in a centered row, gap spacing.xl (20pt) between:
    1. White:  fill #FFFFFF, border 0.5pt separator.opaque
    2. Sepia:  fill #FDF6E3 (mirror existing READER_THEMES.yellow.background
               but slightly warmer for Apple Books match)
    3. Gray:   fill #E5E5EA (new — between sepia and dark)
    4. Black:  fill #000000

  Each:
    - 40pt diameter, radius.full
    - PressableScale (scale 0.92, haptic 'selection')
    - Selected: 2pt ring of accent.primary at radius.full + 4pt outset
      (rendered with an outer wrapper view)
    - Label below: typography.scale.caption (12pt), label.secondary

Note: Phase 3 keeps 3 themes for now (white, sepia, dark) — "gray" is
a designer-proposed 4th. If `READER_THEMES` migration adds 'gray',
ship 4 tiles; otherwise ship 3. Architect's call. Recommendation: SHIP
3 tiles in Phase 3 to avoid migration noise; add gray in Phase 6.
```

Sheet does NOT close on any change. User scrubs font-size repeatedly, watches the book reflow in real time behind the sheet. Closes only on grabber-pull-down or backdrop tap.

### 3.5 NoteEditor Sheet

```
┌──────────────────────────────────────┐
│            ▬▬▬                       │
│  Note                                │
│                                      │
│  ┌──────────────────────────────┐    │
│  │                              │    │  ← TextInput, multiline
│  │  Type your note here…        │    │     min height 120pt
│  │                              │    │     placeholder color label.tertiary
│  │                              │    │     body 17pt
│  └──────────────────────────────┘    │
│                                      │
│  ┌──────────────┬──────────────┐    │
│  │  Discard     │     Save     │    │  ← buttons row
│  └──────────────┴──────────────┘    │
└──────────────────────────────────────┘

Sheet props:  snapPoints={[320]}, keyboardBehavior="interactive"
Background:   colors.background.secondary

TextInput:
  - bg: background.primary, radius.lg, padding spacing.md
  - autoFocus on open
  - placeholderTextColor: label.tertiary
  - testID: 'note-input'

Buttons row (44pt height, gap spacing.md):
  Discard:
    - PressableScale, full-width left half
    - bg: fill.tertiary, radius.lg
    - text: body semibold, label.primary
    - haptic: 'soft'
    - testID: 'note-discard'
  Save:
    - PressableScale, full-width right half
    - bg: accent.primary, radius.lg
    - text: body semibold, '#FFFFFF'
    - haptic: 'medium'
    - testID: 'note-save'
```

---

## 4. Visual state matrix

The decision that drives this whole spec: **sheets always use the system theme, never the reader theme.** This decouples sheet appearance from the book's paper color.

| Surface | Light mode | Dark mode | Sepia reader mode |
|---|---|---|---|
| Top toolbar bg | `<BlurView tint='systemUltraThinMaterialLight'/>` intensity 80 | `<BlurView tint='systemUltraThinMaterialDark'/>` intensity 80 | same as light (chrome ignores reader theme) |
| Top toolbar text | `colors.label.primary` | `colors.label.primary` | `colors.label.primary` |
| Top toolbar hairline | `colors.separator.nonOpaque` | `colors.separator.nonOpaque` | same as light |
| Bottom toolbar bg | same as top | same as top | same as top |
| Bottom toolbar chapter text | `colors.label.secondary` | `colors.label.secondary` | same as light |
| Progress pill bg | `colors.fill.tertiary` | `colors.fill.tertiary` | same as light |
| Progress pill text | `colors.label.secondary` | `colors.label.secondary` | same as light |
| Sheet bg | `colors.background.secondary` (#F2F2F7) | `colors.background.secondary` (#1C1C1E) | **same as system** (NOT sepia) |
| Sheet title | `colors.label.primary` | `colors.label.primary` | same as system |
| ListRow bg | transparent (sheet bg shows through) | transparent | transparent |
| ListRow title | `colors.label.primary` | `colors.label.primary` | same as system |
| ListRow subtitle | `colors.label.secondary` | `colors.label.secondary` | same as system |
| ListRow hairline | `colors.separator.nonOpaque` | `colors.separator.nonOpaque` | same as system |
| SegmentedControl track | `colors.fill.primary` | `colors.fill.primary` | same as system |
| SegmentedControl pill (selected) | `colors.background.primary` + `shadow.low` | `colors.fill.tertiary` | same as system |
| SearchBar bg | `colors.fill.secondary` | `colors.fill.secondary` | same as system |
| EmptyState icon tint | `colors.label.tertiary` | `colors.label.tertiary` | same as system |
| EmptyState title | `colors.label.primary` | `colors.label.primary` | same as system |
| Reader content bg | `colors.reader.paperPureWhite` (white theme) OR `reader.paper` (default) | `colors.reader.paper` (true black) | `colors.reader.paperSepia` |
| Reader content text | `colors.reader.ink` (light) | `colors.reader.ink` (dark) | `#5B4636` (sepia ink, kept from existing `READER_THEMES.yellow.color`) |
| AnnotationPopover bg | `colors.background.secondary` + `shadow.medium` | `colors.background.secondary` + `shadow.medium` | same as system |
| AnnotationPopover text | `colors.label.primary` | `colors.label.primary` | same as system |

### 4.1 Key decision

**Sheets do not follow the reader theme.** Even when the user is reading in sepia or dark mode, the sheet that slides up is the system-themed secondary surface. This matches Apple Books exactly. The book stays warm cream; the controls are neutral gray.

This is a deliberate break from the current code where every sheet takes `theme: ReaderTheme` and paints itself sepia. The migration:
- `sheetRef.backgroundStyle = { backgroundColor: theme.background }` → `backgroundColor: colors.background.secondary`
- Remove all `style={{ color: theme.color }}` from sheet text — use `colors.label.primary` / `colors.label.secondary` instead

Detox snapshot tests that check sheet colors against reader theme will break (R4). They must be updated to check against `colors.background.secondary`.

### 4.2 What still follows reader theme

- The book content surface itself (engine bg + ink color) — `READER_THEMES[settings.themeName]` remains the source of truth.
- The book content text styling (font family, font size%) — `reader-settings` remain.
- Highlight tint colors painted onto the book content — `colors.highlight.*` mapped via name.

Nothing else.

---

## 5. Motion vocabulary in the reader

| Surface | Animation | Token | Duration |
|---|---|---|---|
| Chrome show/hide | Opacity fade, both bars together | `motion.timing.fast` | 200ms |
| Sheet open | Spring from bottom (gorhom default + override) | `motion.spring.gentle` | ~280ms perceived |
| Sheet close | Spring downward (gorhom default) | `motion.spring.gentle` | ~220ms |
| Backdrop opacity | Timing fade | `motion.timing.fast` | 200ms |
| IconButton press | Scale 1 → 0.95 → 1 | `motion.spring.snappy` (via PressableScale) | ~120ms each leg |
| SegmentedControl pill translate | translateX | `motion.spring.snappy` | ~150ms |
| Progress pill value change | NONE — value swaps silently | — | 0ms |
| Theme tile selection | Outer ring fades in | `motion.timing.fast` | 200ms |
| Font size apply | Engine reflows on its own schedule | — | engine-driven |
| AnnotationPopover fade | Existing FadeIn 150ms | `motion.timing.fast` | 200ms (rounded up to use existing token) |
| Highlight swatch tap | PressableScale 0.92 (slightly more bounce — these are play-y) | `motion.spring.bouncy` | ~150ms |
| Page turn | Engine default (EPUB: paginated swipe; PDF: scroll; MOBI/DJVU: instant) | — | engine-driven |

### 5.1 Reduce motion fallback

When `useTheme().reduceMotion === true`:
- Chrome fade duration → 0 (instant show/hide).
- Sheet open → fade-in-place (no slide), `motion.timing.normal` duration.
- PressableScale → opacity 0.7 (no scale transform).
- SegmentedControl pill → instant move (no translate animation).
- All other motion already follows tokens, which respect reduce-motion via the centralized fallback in primitives.

---

## 6. Haptics in the reader

Source: `expo-haptics`. Mapping:

| Action | Haptic |
|---|---|
| Tap toolbar icon (TOC, Aa, bookmark, search) | `Haptics.impactAsync(ImpactFeedbackStyle.Light)` |
| Toggle chrome (single tap content) | `Haptics.impactAsync(ImpactFeedbackStyle.Soft)` |
| Tap progress pill (PDF go-to-page) | `Haptics.impactAsync(ImpactFeedbackStyle.Light)` |
| Bookmark added | `Haptics.notificationAsync(NotificationFeedbackType.Success)` |
| Bookmark removed | `Haptics.impactAsync(ImpactFeedbackStyle.Soft)` |
| Highlight created | `Haptics.impactAsync(ImpactFeedbackStyle.Light)` |
| Highlight color changed | `Haptics.selectionAsync()` |
| Highlight deleted | `Haptics.notificationAsync(NotificationFeedbackType.Warning)` |
| Sheet open (settle) | `Haptics.impactAsync(ImpactFeedbackStyle.Soft)` — fire when sheet's `onAnimate` settles, NOT on the tap |
| Sheet dismiss via swipe | NONE — iOS already plays a system haptic |
| Sheet dismiss via backdrop tap | NONE |
| SegmentedControl change | `Haptics.selectionAsync()` |
| Theme tile selection | `Haptics.selectionAsync()` |
| Font size step | `Haptics.selectionAsync()` |
| TTS play/pause | handled in Phase 4 (MiniPlayer) — leave existing TTSControls haptics in place |
| Realtime voice toggle | handled in Phase 4 |

Reduce-motion proxy: when `reduceMotion === true`, suppress all haptics (iOS doesn't expose a Reduce Haptics setting; this is the standard correlate per Phase 2 Section 10.7).

---

## 7. Accessibility

### 7.1 Labels (required)

All IconButtons MUST pass `accessibilityLabel` via the `label` prop. Concrete strings:

| Button | accessibilityLabel |
|---|---|
| Back | "Back to library" |
| TOC | "Table of contents" |
| Aa | "Appearance and font size" |
| Bookmark (outline, not bookmarked) | "Add bookmark" |
| Bookmark (filled, bookmarked) | "Remove bookmark" |
| Search | "Search the book" |
| Zoom out (DJVU) | "Zoom out" |
| Zoom in (DJVU) | "Zoom in" |
| Trash inside list rows | `Delete ${rowTitle}` |

Progress pill: `accessibilityRole='button'` only when tappable (PDF). `accessibilityLabel={progress.label}` for everyone.

### 7.2 VoiceOver order

When chrome is visible:
1. Top toolbar (back → title)
2. Content (engine — engine handles its own a11y tree)
3. Bottom toolbar (chapter title → progress pill → action cluster left to right)

When a sheet is open:
- `accessibilityViewIsModal={true}` on the sheet container (Sheet primitive handles this).
- VoiceOver focus moves to the sheet title on open (built into `Sheet`).
- Background a11y is excluded.

### 7.3 Modality

- Top toolbar: `accessibilityViewIsModal={false}` (it's chrome, not a modal).
- Bottom toolbar: `accessibilityViewIsModal={false}`.
- Sheets: `accessibilityViewIsModal={true}` (Sheet primitive default).

### 7.4 Dynamic Type

All text in chrome and sheets uses typography tokens (pt-based). Default RN `allowFontScaling={true}` is honored. No primitive overrides this.

The progress pill width is NOT fixed — it grows with Dynamic Type. The chapter title slot truncates with `numberOfLines={1}` so it shrinks gracefully when the pill grows.

### 7.5 Reduce Motion

Fade duration → 0. Sheets fade in place. PressableScale → opacity. (See Section 5.1.)

### 7.6 Touch targets

All IconButtons are 22pt icons in a 44×44 pressable (via hitSlop). Tap targets meet iOS HIG 44pt minimum. The `Aa` font-size buttons in the Appearance Sheet are explicit 44pt circles.

---

## 8. Token mapping for migration

Map current `ReaderTheme` (`apps/mobile/types/book.ts`) to new tokens.

| Old field | Fate | New source |
|---|---|---|
| `theme.background` | **KEEP** | Still used as the book content paper color via `READER_THEMES[themeName].background`. The engine's `defaultTheme.body.background` reads from here. |
| `theme.color` | **KEEP** | Book content text color via `READER_THEMES[themeName].color`. |
| `theme.toolbarBg` | **DELETE** | Replaced by `<Toolbar blur={true} transparent={true}>`. The blur material (systemUltraThinMaterial*) handles tinting natively. |
| `theme.toolbarText` | **DELETE** | Replaced by `colors.label.primary` (always). |
| `theme.swatchColor` | **KEEP** | Used by Appearance Sheet's theme tiles. Maps to one of: light=`#FFFFFF`, sepia=`#FDF6E3`, dark=`#000000`. (Existing values are close enough; minor tweak for Apple-Books warmth on sepia.) |
| `theme.swatchBorder` | **KEEP** | Used by Appearance Sheet's theme tiles for the outline ring. Maps to `colors.separator.opaque` (light tile) or transparent (dark tile). |
| `theme.label` | **KEEP** | User-facing theme name ("Light" / "Sepia" / "Dark"). |
| `theme.name` | **KEEP** | Internal key. |

After migration the `ReaderTheme` type shrinks to: `{ name, label, background, color, swatchColor, swatchBorder }` — `toolbarBg` and `toolbarText` are gone.

### 8.1 Sheet theme prop removal

Every sheet currently accepts `theme: ReaderTheme`. Phase 3 removes this prop entirely. Sheets read `useTheme()` for system colors and never touch reader theme.

Components affected:
- `AppearanceSheet` — keeps `settings` prop (font, theme name); drops `theme`.
- `TocSheet` — drops `theme`.
- `HighlightsSheet` — drops `theme`.
- `BookmarksList` — drops `theme`.
- `SearchPanel` — drops `theme`.
- `NoteEditor` — drops `theme`. (PDF's `PDF_NOTE_EDITOR_THEME` constant in `pdf/[id].tsx` is deleted.)

### 8.2 ReaderToolbar deletion

`apps/mobile/components/ReaderToolbar.tsx` — DELETE entirely once all four format screens migrate to `ReaderShell`.

---

## 9. Font size scale resolution (R7)

**Decision: keep the existing % storage internally; display pt in the UI.**

- Storage (`lib/reader-settings.ts`): unchanged. `fontSize: number` continues to range 80–150 in 10-step increments.
- Engine: `changeFontSize(`${size}%`)` continues to receive the raw % value.
- UI display in AppearanceSheet's center label: derived as `Math.round(16 * (settings.fontSize / 100))` pt.

Concrete conversion table:

| Stored % | Displayed pt |
|---|---|
| 80 | 13 |
| 90 | 14 |
| 100 | 16 |
| 110 | 18 |
| 120 | 19 |
| 130 | 21 |
| 140 | 22 |
| 150 | 24 |

The Aa- / Aa+ buttons step `settings.fontSize` by ±10 (the existing increment). The pt label updates accordingly. No data migration. No engine change.

The displayed pt range (13–24) is within the `reader-body` 14–22pt window of the Phase 2 typography spec — close enough; the existing 80%/150% bounds are kept so user preferences survive.

---

## 10. ReaderShell file plan

```
apps/mobile/components/reader/
  ReaderShell.tsx          — main component; owns chrome + sheets + timer
  ReaderTopBar.tsx         — top bar internals (back, title)
  ReaderBottomBar.tsx      — bottom bar internals (chapter, pill, cluster)
  ReaderProgressPill.tsx   — the pill in the center slot
```

### 10.1 ReaderShell responsibilities

ReaderShell owns:
- Mounting top + bottom Toolbar (via `Toolbar` Phase 2 primitive)
- Mounting all sheet components (TocSheet, AppearanceSheet, HighlightsSheet, BookmarksSheet, SearchSheet, NoteEditorSheet)
- Sheet open/close booleans as `useState` (no refs leaking out)
- Auto-hide timer with TTS/voice/sheet-open guards
- Chrome visibility state + the fade animation
- The full-area Pressable for tap-to-toggle (PDF/MOBI/DJVU); imperative handle (EPUB)
- testID host: `reader-toggle-toolbar`, `reader-position-indicator` (positional; format screens still drive the indicator's accessibilityLabel)

### 10.2 ReaderShell props

```ts
type ReaderShellProps = {
  // Identity
  testID: 'reader-epub' | 'pdf-reader' | 'mobi-reader' | 'djvu-reader';

  // Top bar
  title: string;
  onBack: () => void;

  // Bottom bar slots
  chapterTitle?: string;                    // bottom-left, truncated
  progress?: {                              // bottom-center
    label: string;                          // pre-formatted, e.g. "Page 42 of 310"
    onPress?: () => void;                   // optional tappable (PDF)
  };

  // Action cluster (bottom-right) — order in array = render order left-to-right
  actions: Array<
    | { kind: 'toc'; onPress: () => void }
    | { kind: 'aa'; onPress: () => void }
    | { kind: 'bookmark'; onPress: () => void; isBookmarked: boolean }
    | { kind: 'search'; onPress: () => void; disabled?: boolean }
    | { kind: 'zoomOut'; onPress: () => void; disabled?: boolean }
    | { kind: 'zoomIn'; onPress: () => void; disabled?: boolean }
  >;

  // Chrome control (advanced — most callers omit)
  chromeVisible?: boolean;                  // controlled mode; if omitted, ReaderShell self-manages
  onChromeVisibleChange?: (next: boolean) => void;
  contentTapsHandledByEngine?: boolean;     // EPUB sets true (engine sends onSingleTap)

  // Auto-hide guards
  ttsActive?: boolean;
  realtimeActive?: boolean;

  // Sheets — pass children-as-renderers
  renderTocSheet?: (props: { isOpen: boolean; onClose: () => void }) => ReactNode;
  renderAppearanceSheet?: (props: { isOpen: boolean; onClose: () => void }) => ReactNode;
  renderHighlightsSheet?: (props: { isOpen: boolean; onClose: () => void }) => ReactNode;
  renderSearchSheet?: (props: { isOpen: boolean; onClose: () => void }) => ReactNode;
  renderNoteEditorSheet?: (props: { isOpen: boolean; onClose: () => void }) => ReactNode;
  // (Bookmarks is rendered inside TocSheet as a tab — no separate slot)

  // E2E observability — exposes the current position to Detox
  positionLabel?: string;                   // drives accessibilityLabel on
                                            // `reader-position-indicator`

  children: ReactNode;                      // the reader engine
};
```

ReaderShell's `actions` array drives the right cluster. Format screens build it conditionally:

```ts
const actions: ReaderShellProps['actions'] = [];
if (hasToc) actions.push({ kind: 'toc', onPress: openToc });
if (hasAppearance) actions.push({ kind: 'aa', onPress: openAppearance });
actions.push({ kind: 'bookmark', onPress: toggleBookmark, isBookmarked });
if (hasSearch) actions.push({ kind: 'search', onPress: openSearch });
if (hasZoom) {
  actions.push({ kind: 'zoomOut', onPress: zoomOut });
  actions.push({ kind: 'zoomIn', onPress: zoomIn });
}
```

### 10.3 Sheet ownership

Sheets are passed as render props rather than booleans, because each sheet needs format-specific data (highlights list, TOC array, bookmarks). The format screen knows that data; ReaderShell only knows when to mount.

```ts
<ReaderShell
  ...
  renderTocSheet={({ isOpen, onClose }) => (
    <TocSheet
      isOpen={isOpen}
      onClose={onClose}
      toc={toc}
      currentHref={currentHref}
      onSelectChapter={handleSelectChapter}
      bookmarks={bookmarks}
      onNavigateToBookmark={handleNavigateToBookmark}
      onDeleteBookmark={handleDeleteBookmark}
    />
  )}
  ...
>
```

The previous `useRef<BottomSheet>` pattern across format screens is eliminated. ReaderShell holds `tocOpen`, `appearanceOpen`, etc., as plain useState booleans and passes them down.

### 10.4 Format screens become thin

After this refactor, `app/reader/[id].tsx` (EPUB) is mostly: load book → wire `useReader()` callbacks → build `actions` + `renderSheet` props → `<ReaderShell>{<Reader />}</ReaderShell>`. All chrome state lives in ReaderShell.

---

## 11. Critical Detox testID preservation

Every existing testID must appear in the new layout. New location specified for each:

| testID | New location |
|---|---|
| `reader-epub` | EPUB screen's `<ReaderShell testID="reader-epub">` — ReaderShell forwards to its root `<View>` |
| `pdf-reader` | PDF screen's `<ReaderShell testID="pdf-reader">` |
| `mobi-reader` | MOBI screen's `<ReaderShell testID="mobi-reader">` |
| `djvu-reader` | DJVU screen's `<ReaderShell testID="djvu-reader">` |
| `reader-loading` | Unchanged — still in the format screens' loading state (before ReaderShell mounts) |
| `reader-toggle-toolbar` | ReaderShell's full-area Pressable (PDF/MOBI/DJVU). For EPUB, mount a hidden 0×0 view with this testID + `accessibilityActions={[{ name: 'activate' }]}` that calls `toggleChrome()`, so Detox `element(by.id(...)).tap()` still works. |
| `reader-next-page-btn` | DELETED from PDF — chrome no longer exposes prev/next page buttons (Apple Books has none either). The Detox test must be updated to use `swipe('left')` on `pdf-reader` instead. ALTERNATIVELY: keep the next-page button in PDF's right cluster as a 5th icon. **Recommendation: KEEP IT** for now — the test is too useful to break, and a "next page" button is a reasonable PDF affordance. Render as `IconButton name="chevron.forward"` to the right of bookmark, with testID. |
| `reader-position-indicator` | ReaderShell renders this as an absolute-positioned 0×0 view; format screens pass `positionLabel` prop (EPUB: currentHref/cfi; PDF: `${pageNumber}/${pageCount}`; MOBI: chapter; DJVU: page). |
| `search-input` | The SearchBar's inner TextInput inside the Search sheet. SearchBar primitive must forward a `testID` prop to its TextInput. |
| `search-no-results` | EmptyState's container in the Search sheet's "no matches" state. EmptyState primitive must forward `testID`. |
| `search-prompt` | EmptyState's container in the Search sheet's initial state. |
| `bookmarks-empty` | EmptyState's container in the TOC sheet's Bookmarks tab when bookmarks.length === 0. |
| `bookmark-row-${id}` | Each ListRow inside the TOC sheet's Bookmarks tab. ListRow primitive forwards `testID`. |

New testIDs introduced (none are required by current Detox suites; add for future tests):
- `reader-top-toolbar`, `reader-bottom-toolbar`
- `progress-pill`
- `toc-row-${index}`
- `highlight-row-${id}`
- `search-result-${i}`
- `appearance-sheet`, `toc-sheet`, `highlights-sheet`, `search-sheet`, `note-editor-sheet`

---

## 12. Migration order (per-format)

Each step lands as one or more atomic commits and leaves the app in a working state.

1. **Build ReaderShell scaffolding.** Land ReaderShell + ReaderTopBar + ReaderBottomBar + ReaderProgressPill with no consumers. Unit tests for the shell (chrome visibility, auto-hide timer, action rendering). Format screens still use the old ReaderToolbar.

2. **Migrate sheets in place.** Refactor AppearanceSheet, TocSheet, HighlightsSheet, BookmarksList → BookmarksTab (folded into TocSheet), SearchPanel, NoteEditor to use the Phase 2 `Sheet` primitive + system theme + ListRow/SegmentedControl/etc. Drop the `theme: ReaderTheme` prop everywhere. Sheets still mount inside the existing format screens. Update Detox snapshots/colors.

3. **Migrate EPUB reader.** `app/reader/[id].tsx` adopts `<ReaderShell>`. Drop the inline `<ReaderToolbar>`. All sheets passed via render props. Update unit + Detox tests. **Ship.**

4. **Migrate PDF reader.** `app/reader/pdf/[id].tsx` adopts `<ReaderShell>`. Delete inline topbar/bottombar JSX + styles. Migrate the TOC Modal → TocSheet. Keep `reader-next-page-btn`. **Ship.**

5. **Migrate MOBI reader.** `app/reader/mobi/[id].tsx` adopts `<ReaderShell>`. Sheets mounted: Appearance only. Bookmark toggle wired. **Ship.**

6. **Migrate DJVU reader.** `app/reader/djvu/[id].tsx` adopts `<ReaderShell>`. Same sheets as MOBI + zoom buttons in cluster. **Ship.**

7. **Delete old ReaderToolbar.** Remove `apps/mobile/components/ReaderToolbar.tsx` once `git grep ReaderToolbar` returns 0 results. Remove the `theme.toolbarBg` / `theme.toolbarText` fields from the `ReaderTheme` type. **Ship.**

Each step keeps tests green: `pnpm -C apps/mobile test` + Detox smoke suite on at least one format per step.

---

## 13. ASCII mockups

### 13.1 Reader with chrome hidden

```
┌─────────────────────────────────────────────┐
│                                             │  ← status bar shows through
│                                             │
│                                             │
│  Chapter 1: Introduction                    │  ← book content, no chrome
│                                             │
│  The whole of philosophy is in two words:   │
│  sustain and abstain. Of the things which   │
│  are in our power, some are good, others    │
│  bad; and of those things which are not in  │
│  our power, some are good, others bad.      │
│                                             │
│  We must therefore, in all things, look to  │
│  what is in our own power, and act upon     │
│  it accordingly.                            │
│                                             │
│                                             │
│                                             │
│                                             │
│                                             │
│                                             │
└─────────────────────────────────────────────┘
```

### 13.2 Reader with chrome visible (EPUB)

```
╔═════════════════════════════════════════════╗
║░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░║░░ ← status bar (transparent)
║                                             ║
║░<   The Discourses                          ║░░ ← top toolbar (BlurView)
║─────────────────────────────────────────────║░░ ← hairline
╠═════════════════════════════════════════════╣
│                                             │
│  Chapter 1: Introduction                    │
│                                             │
│  The whole of philosophy is in two words:   │
│  sustain and abstain. Of the things which   │
│  are in our power, some are good, others    │  ← book content
│  bad; and of those things which are not in  │
│  our power, some are good, others bad.      │
│                                             │
│  We must therefore, in all things, look to  │
│  what is in our own power, and act upon     │
│  it accordingly.                            │
│                                             │
╠═════════════════════════════════════════════╣
║─────────────────────────────────────────────║░░ ← hairline
║░Chapter 1     ╭13 min left╮      ▤ Aa ⚐ ⌕░░║░░ ← bottom toolbar (BlurView)
║░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░║░░ ← safe-area bottom
╚═════════════════════════════════════════════╝
```

### 13.3 TOC sheet open

```
╔═════════════════════════════════════════════╗
║░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░║
║░<   The Discourses                          ║
║─────────────────────────────────────────────║
║                                             ║
║  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ║  ← scrim, fade-in
║  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ║     timing.fast
║  ╔═════════════════════════════════════════╗║
║  ║              ▬▬▬                        ║║  ← grabber
║  ║  Table of Contents                      ║║
║  ║                                         ║║
║  ║  ┌─ Contents ─┬─ Bookmarks ─┐           ║║  ← SegmentedControl
║  ║  └────────────┴─────────────┘           ║║     (Contents selected)
║  ║                                         ║║
║  ║  Chapter 1: Introduction        ✓       ║║  ← ListRow + check
║  ║  ─────────────────────────────────      ║║
║  ║  Chapter 2: First Principles            ║║
║  ║  ─────────────────────────────────      ║║
║  ║    Section 2.1: On Volition             ║║  ← depth 1 indent
║  ║  ─────────────────────────────────      ║║
║  ║    Section 2.2: On Constraint           ║║
║  ║  ─────────────────────────────────      ║║
║  ║  Chapter 3: The Practice                ║║
║  ║                                         ║║
║  ║  ...                                    ║║
║  ╚═════════════════════════════════════════╝║
╚═════════════════════════════════════════════╝
```

### 13.4 Appearance sheet open

```
╔═════════════════════════════════════════════╗
║░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░║
║░<   The Discourses                          ║
║─────────────────────────────────────────────║
║                                             ║
║  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ║  ← scrim
║  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ║
║  ░░░ Book content visible through scrim ░░░ ║
║  ╔═════════════════════════════════════════╗║
║  ║              ▬▬▬                        ║║
║  ║                                         ║║
║  ║   ⊝   Aa-      16pt      Aa+    ⊕      ║║  ← font size row
║  ║                                         ║║
║  ║  ┌─ Serif ─────┬───── Sans ─┐           ║║  ← font picker (EPUB only)
║  ║  └─────────────┴────────────┘           ║║
║  ║                                         ║║
║  ║                                         ║║
║  ║         ⚪      🟡      ⚫             ║║  ← 3 theme tiles (40pt)
║  ║       Light   Sepia   Dark              ║║
║  ║                                         ║║
║  ╚═════════════════════════════════════════╝║
╚═════════════════════════════════════════════╝
```

### 13.5 Bookmarks tab (inside TOC sheet) open

```
╔═════════════════════════════════════════════╗
║░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░║
║░<   The Discourses                          ║
║─────────────────────────────────────────────║
║                                             ║
║  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ║
║  ╔═════════════════════════════════════════╗║
║  ║              ▬▬▬                        ║║
║  ║  Table of Contents                      ║║
║  ║                                         ║║
║  ║  ┌─ Contents ─┬─ Bookmarks ─┐           ║║  ← Bookmarks selected
║  ║  └────────────┴─────────────┘           ║║
║  ║                                         ║║
║  ║  🔖  Chapter 5: The Argument        🗑  ║║  ← bookmark row
║  ║     May 21 · 13:42                      ║║
║  ║  ─────────────────────────────────      ║║
║  ║  🔖  Chapter 8: Counterexamples     🗑  ║║
║  ║     May 20 · 09:11                      ║║
║  ║  ─────────────────────────────────      ║║
║  ║  🔖  Chapter 12: A Reply            🗑  ║║
║  ║     May 19 · 22:03                      ║║
║  ║                                         ║║
║  ╚═════════════════════════════════════════╝║
╚═════════════════════════════════════════════╝

If empty:
  ╔═════════════════════════════════════════╗
  ║              ▬▬▬                        ║
  ║  Table of Contents                      ║
  ║                                         ║
  ║  ┌─ Contents ─┬─ Bookmarks ─┐           ║
  ║  └────────────┴─────────────┘           ║
  ║                                         ║
  ║                                         ║
  ║                                         ║
  ║              ┌─────┐                    ║
  ║              │  🔖 │                    ║
  ║              └─────┘                    ║
  ║                                         ║
  ║         No bookmarks yet                ║
  ║                                         ║
  ║  Tap the bookmark icon on any page to   ║
  ║         save your place.                ║
  ║                                         ║
  ╚═════════════════════════════════════════╝
  testID="bookmarks-empty" on the EmptyState container
```

---

## 14. Decisions summary

The opinionated calls made in this spec:

1. **4-icon right cluster**, not 5. Highlights folds into the TOC sheet — never. Wait. Highlights is its own sheet (Section 3.2). The right cluster is **TOC, Aa, bookmark, search** for EPUB. To access highlights, the user opens TOC → there is no third tab. **Where do highlights live?** Designer call: highlights are accessed by tapping a highlighted passage in the book (existing AnnotationPopover) OR via a future "Notes" tab in TOC (Phase 6). For Phase 3, the **HighlightsSheet remains mountable** and is accessed via a long-press menu item or future right-cluster icon — but it is **NOT** in the default 4-icon cluster. If we must surface it from chrome: replace the bookmark icon with a "more" overflow menu (3 dots) that shows bookmark + highlights. **Recommendation: 5-icon cluster for EPUB**, accept the slight density: `[ TOC ][ Aa ][ bookmark ][ highlights ][ search ]`. Tap targets stay at 44pt; visible icons at 22pt with `spacing.sm` (8pt) between — fits within ~280pt available right-cluster width on iPhone SE.

   **Final call: 5 icons for EPUB. 4 for DJVU (no search/highlights). 2 for PDF (TOC + bookmark, plus the legacy next-page). 2 for MOBI (Aa + bookmark).**

2. Sheets always system-themed, never reader-themed. Hard break with current code.

3. Bookmarks list lives as a tab inside TOC sheet (one fewer sheet to maintain; matches Apple Books iPad).

4. Font size stays as % internally, displayed as pt.

5. Long-press to delete is removed everywhere; trailing trash IconButtons replace it.

6. Brightness slider deferred to Phase 6.

7. 4th "gray" theme tile deferred to Phase 6. Phase 3 ships 3 tiles.

8. PDF keeps `reader-next-page-btn` (don't break the Detox test).

9. PDF starts chrome hidden, with a 2s first-mount peek for discoverability.

10. Chrome animation is opacity-only, 200ms. No slide. Both bars together.

---

End of UI-SPEC. Architect: please produce `.parity-v2/phase3-reader-ui/ARCH.md` with the precise file plan, contracts, and refactor sequence.
