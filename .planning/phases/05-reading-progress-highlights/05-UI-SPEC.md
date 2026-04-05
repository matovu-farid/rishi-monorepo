---
status: draft
phase: 05
phase_name: Reading Progress & Highlights
design_system: NativeWind (Tailwind CSS for React Native)
created: 2026-04-06
revised: 2026-04-06
---

# UI-SPEC: Phase 05 - Reading Progress & Highlights

## Design System

**Tool:** NativeWind v4 (Tailwind CSS classes in React Native)
**Component library:** Custom components with @gorhom/bottom-sheet, react-native-reanimated
**Icon library:** @expo/vector-icons via IconSymbol wrapper (SF Symbols on iOS, MaterialIcons on Android)
**Animation:** react-native-reanimated (FadeIn/FadeOut already used in ReaderToolbar)

## Spacing

Scale: 4px base unit (8-point system)

| Token | Value | Usage |
|-------|-------|-------|
| `p-1` | 4px | Icon-to-label gap in menu items |
| `p-2` | 8px | Inner padding of highlight color swatches |
| `p-4` | 16px | Vertical padding of list rows, horizontal screen padding, sheet content padding |
| `p-6` | 24px | Sheet section spacing, bottom sheet content padding |
| `p-8` | 32px | Empty state vertical padding |

Touch targets: 44x44px minimum (existing pattern: `w-11 h-11` used throughout).

## Typography

Font family: System fonts via `Fonts` constant (system-ui on iOS, normal on Android).

| Role | Size | Weight | Line Height | Tailwind Class |
|------|------|--------|-------------|----------------|
| Sheet title | 18px | 600 (semibold) | 1.3 | `text-lg font-semibold` |
| Body / list text | 16px | 400 (regular) | 1.5 | `text-base` |
| Secondary / metadata | 14px | 400 (regular) | 1.4 | `text-sm` |
| Annotation note preview | 14px | 400 (regular) | 1.4 | `text-sm` |
| Highlight text excerpt | 14px | 400 (regular) | 1.5 | `text-sm leading-relaxed` |

Only 2 weights used: regular (400) and semibold (600). Matches existing pattern.

## Color

### App Chrome (follows existing Colors constant)

| Role | Light | Dark | Split |
|------|-------|------|-------|
| Dominant surface | `#FFFFFF` | `#151718` | 60% |
| Secondary surface (cards, sheets) | `#F9FAFB` (gray-50) | `#1E2022` | 30% |
| Accent (tint) | `#0a7ea4` | `#FFFFFF` | 10% |
| Destructive | `#DC2626` (red-600) | `#DC2626` | -- |
| Icon default | `#687076` | `#9BA1A6` | -- |
| Text primary | `#11181C` | `#ECEDEE` | -- |
| Text secondary | `#687076` (gray-500) | `#9BA1A6` (gray-400) | -- |

### Reader Chrome (follows READER_THEMES)

Reader toolbar and sheets inherit the active reader theme (`white`, `dark`, `yellow`) using `theme.toolbarBg`, `theme.toolbarText`, `theme.background`, `theme.color`. No new reader theme colors are introduced.

### Highlight Colors

Four highlight colors. The user selects one when creating a highlight. Default is yellow.

| Name | Hex | Opacity | Usage |
|------|-----|---------|-------|
| Yellow | `#FBBF24` | 0.3 | Default highlight color |
| Green | `#34D399` | 0.3 | Optional highlight color |
| Blue | `#60A5FA` | 0.3 | Optional highlight color |
| Pink | `#F472B6` | 0.3 | Optional highlight color |

These colors are passed to `@epubjs-react-native` `AnnotationStyles.color` and `AnnotationStyles.opacity`.

### Accent Reserved For

- Toolbar active highlight button (when in highlight mode)
- TOC current-chapter indicator (existing)
- "Add Note" button in annotation popover
- Sync status indicator (synced checkmark)

## Component Inventory

### New Components

| Component | Type | Purpose | Focal Point |
|-----------|------|---------|-------------|
| `HighlightMenu` | Popover (absolute positioned View) | Appears above selected text with color swatches and "Add Note" action | The color swatch row -- user's eye goes to the four colored circles first |
| `AnnotationPopover` | Popover (absolute positioned View) | Appears when tapping existing highlight: shows note preview, "Edit Note", "Delete", "Change Color" | The action row at the bottom -- user's eye goes to the three action buttons |
| `HighlightsSheet` | BottomSheet | Full highlights list for a book, opened from reader toolbar | The first highlight row -- the list content is the reason the sheet was opened |
| `NoteEditor` | BottomSheet with TextInput | Sheet for adding/editing a note on a highlight | The TextInput field -- it is the primary interactive element |
| `HighlightRow` | List item (View) | Single highlight in the list: excerpt, note preview, color indicator, chapter label | -- |
| `SyncStatusBadge` | Inline View | Small indicator showing sync state (synced/pending/error) | -- |

### Modified Components

| Component | Change |
|-----------|--------|
| `ReaderToolbar` | Add highlights list button (bookmark icon) between TOC and appearance buttons |
| `Reader` (in `reader/[id].tsx`) | Enable `enableSelection={true}`, add `menuItems`, `onSelected`, `onAddAnnotation`, `onPressAnnotation`, `onChangeAnnotations`, `initialAnnotations` props |

### Existing Components (No Changes)

- `TocSheet` -- no changes
- `AppearanceSheet` -- no changes
- `BookRow` -- no changes
- `LibraryEmptyState` -- no changes

## Layout

### HighlightMenu (Text Selection Popover)

**Focal point:** The color swatch row -- four colored circles draw the eye immediately on appear.

```
+---------------------------------------------+
|  [Yellow] [Green] [Blue] [Pink]  |  Add Note |
+---------------------------------------------+
```

- Position: absolute, centered above text selection (use coordinates from `onSelected` callback)
- Background: `theme.toolbarBg` with rounded-lg (8px radius)
- Shadow: `shadow-lg` (platform shadow)
- Color swatches: 28x28px circles with 2px border when selected
- "Add Note" text button: accent color text, semibold
- Dismiss: tapping outside or tapping a color (creates highlight immediately)
- Animation: FadeIn.duration(150)

### AnnotationPopover (Existing Highlight Tap)

**Focal point:** The action row at the bottom -- three buttons ("Edit Note", "Change Color", "Delete") are the primary decision the user must make.

```
+-------------------------------------------+
|  "This is the highlighted text excerpt..." |
|  Note: "My annotation here"               |
|  ---------------------------------------- |
|  [Edit Note]  [Change Color]  [Delete]    |
+-------------------------------------------+
```

- Position: absolute, centered above the tapped annotation
- Background: `theme.toolbarBg` with rounded-lg
- Max width: 280px
- Excerpt: 2 lines max, `text-sm`, `theme.color`
- Note: `text-sm`, secondary color, italic, 1 line max
- Action row: horizontal, evenly spaced TouchableOpacity buttons
- "Delete" uses destructive color (#DC2626)
- Animation: FadeIn.duration(150)

### HighlightsSheet (Book Highlights List)

**Focal point:** The first highlight row -- the list content is the reason the user opened the sheet.

```
+-------------------------------------------+
|  [handle indicator]                        |
|  Highlights (12)                           |
|  ---------------------------------------- |
|  [color dot] Chapter 1                     |
|  "The highlighted text excerpt that was    |
|   selected by the user..."                 |
|  Note: My annotation text                  |
|  ---------------------------------------- |
|  [color dot] Chapter 3                     |
|  "Another highlighted passage from the     |
|   book content..."                         |
|  ---------------------------------------- |
|  ... (scrollable FlatList)                 |
+-------------------------------------------+
```

- BottomSheet with snap points: `['50%', '90%']` (matches TocSheet pattern)
- Background: `theme.background`
- Handle indicator: `theme.color`, 36px wide, 4px tall (matches existing sheets)
- Title: "Highlights ({count})" -- `text-lg font-semibold`
- Each row:
  - Vertical padding: `p-4` (16px)
  - Color indicator: 10px circle, left-aligned, matching highlight color
  - Chapter label: `text-xs`, secondary color
  - Excerpt: `text-sm`, primary color, 2 lines max
  - Note (if present): `text-sm`, secondary color, italic, 1 line max
  - Tap: navigates to highlight location in book via `goToLocation(cfiRange)`
  - Swipe-to-delete: not used (matches Phase 3 decision -- use explicit delete button or AnnotationPopover)
- Empty state: centered icon + text (see Copywriting section)

### NoteEditor (Add/Edit Note Sheet)

**Focal point:** The TextInput field -- it is the primary interactive element and occupies the largest area of the sheet.

```
+-------------------------------------------+
|  [handle indicator]                        |
|  Add Note                                  |
|  ---------------------------------------- |
|  "The highlighted text..."  (read-only)    |
|  ---------------------------------------- |
|  [TextInput: multiline, placeholder]       |
|  ---------------------------------------- |
|  [Discard Note]               [Save Note]  |
+-------------------------------------------+
```

- BottomSheet with snap points: `[320]`
- Excerpt: `text-sm`, italic, secondary color, 2 lines max, top section
- TextInput: multiline, 120px min height, `text-base`, primary color, border `border-gray-200 dark:border-gray-700`
- "Save Note" button: accent background (`#0a7ea4`), white text, semibold, rounded-lg, 44px height
- "Discard Note" button (add mode) / "Discard Changes" button (edit mode): text-only, secondary color, 44px touch target
- Keyboard-aware: sheet adjusts when keyboard appears (BottomSheet handles this)

## Interaction Contracts

### Text Selection to Highlight Flow

1. User long-presses text in EPUB reader (enableSelection: true)
2. Native text selection handles appear (OS-provided)
3. `menuItems` prop shows custom context menu items: "Highlight Text" and "Highlight & Note"
4. User taps "Highlight Text": `onSelected(text, cfiRange)` fires, highlight created with default yellow color, saved to SQLite, marked isDirty for sync
5. User taps "Highlight & Note": same as above, then NoteEditor sheet opens
6. Highlight appears immediately in the reader via `addAnnotation` from `useReader`

### Existing Highlight Interaction

1. User taps a highlighted passage in the reader
2. `onPressAnnotation(annotation)` fires
3. AnnotationPopover appears above the annotation
4. Actions: "Edit Note" opens NoteEditor, "Change Color" shows inline color swatches, "Delete" shows confirmation Alert
5. Tapping outside the popover dismisses it

### Highlights List Interaction

1. User taps highlights icon in ReaderToolbar
2. HighlightsSheet opens at 50% snap point
3. User can scroll through all highlights sorted by position in book
4. Tapping a highlight row: sheet closes, reader navigates to that CFI location
5. Long-pressing a highlight row: shows delete confirmation Alert

### Reading Progress Sync

1. On `onLocationChange`: debounced 500ms save of currentCfi/currentPage to SQLite (existing behavior)
2. On save: mark book record as isDirty (existing sync column)
3. Sync engine pushes updated currentCfi/currentPage to D1 on next sync cycle (existing triggers: foreground, write, periodic)
4. On pull: if remote currentCfi/currentPage has newer updatedAt, update local position
5. No UI indicator during sync -- existing sync engine handles this silently
6. Conflict resolution: LWW by updatedAt timestamp (existing pattern)

### Highlight Sync

1. New highlights table in SQLite and D1 (see Data Model below)
2. On highlight create/update/delete: mark isDirty, sync engine pushes
3. On pull: union merge -- never delete a highlight that exists on another device
4. Conflict on same highlight (matched by id): LWW per field (color, note, isDeleted)
5. Annotation note edits use LWW on updatedAt

## Data Model (New Tables)

### highlights table

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PK | UUID, client-generated |
| bookId | TEXT NOT NULL | FK to books.id |
| userId | TEXT | null on mobile, set by server |
| cfiRange | TEXT NOT NULL | ePubCFI range string |
| text | TEXT NOT NULL | Selected text content |
| color | TEXT NOT NULL DEFAULT 'yellow' | yellow, green, blue, pink |
| note | TEXT | Optional annotation text |
| chapter | TEXT | Chapter/section label for display |
| createdAt | INTEGER NOT NULL | Unix timestamp ms |
| updatedAt | INTEGER NOT NULL | Unix timestamp ms |
| syncVersion | INTEGER DEFAULT 0 | Server-assigned monotonic counter |
| isDirty | INTEGER DEFAULT 1 | Needs push |
| isDeleted | INTEGER DEFAULT 0 | Soft delete for sync |

Sync columns follow the exact same pattern as the books table.

## Copywriting

### Primary CTA
- "Highlight Text" -- menu item label when text is selected (verb + noun)
- "Highlight & Note" -- menu item label for highlight with note

### Empty States
- Highlights sheet with no highlights: Icon `highlighter` (SF Symbol) at 40px, gray-400. Title: "No highlights yet". Body: "Select text while reading to create highlights."

### Error States
- Highlight save failure: Toast/inline: "Could not save highlight. Your highlight will be saved when connection is restored."
- Sync conflict (user-visible only if data loss): not applicable -- union merge prevents loss

### Destructive Actions
- Delete highlight: `Alert.alert("Delete Highlight", "This highlight and its note will be removed from all your devices.", [Cancel, Delete])` -- "Delete" button uses destructive style. Note: "Cancel" here is an OS Alert button (permitted), not a custom rendered button.
- No bulk delete in v1

### Labels
- ReaderToolbar highlights button: accessibilityLabel "Highlights"
- HighlightMenu color swatches: accessibilityLabel "{Color} highlight"
- NoteEditor save button: "Save Note"
- NoteEditor discard button (add mode): "Discard Note"
- NoteEditor discard button (edit mode): "Discard Changes"
- NoteEditor placeholder: "Add a note about this passage..."
- NoteEditor title (add): "Add Note"
- NoteEditor title (edit): "Edit Note"

## Accessibility

- All touch targets: 44x44px minimum (existing pattern)
- Highlight colors: chosen to have sufficient contrast at 0.3 opacity on white, dark, and sepia backgrounds
- AnnotationPopover and HighlightMenu: `accessibilityViewIsModal={true}` when visible
- Screen reader: highlight creation announced via `AccessibilityInfo.announceForAccessibility("Highlight created")`
- HighlightsSheet rows: accessibilityLabel includes excerpt text and chapter
- Color swatches: labeled by color name, not just visual

## Animation

| Element | Enter | Exit | Duration |
|---------|-------|------|----------|
| HighlightMenu | FadeIn | FadeOut | 150ms |
| AnnotationPopover | FadeIn | FadeOut | 150ms |
| HighlightsSheet | BottomSheet spring | BottomSheet spring | default |
| NoteEditor | BottomSheet spring | BottomSheet spring | default |
| Highlight in text | Instant (epubjs annotation render) | Instant | 0ms |

## Registry

**Tool:** NativeWind (not shadcn -- React Native project)
**Third-party registries:** none
**Third-party blocks:** none

No registry safety gate required.

## Pre-populated Sources

| Source | Decisions Used |
|--------|---------------|
| REQUIREMENTS.md | HIGH-01 through HIGH-07 requirements |
| ROADMAP.md | Phase 5 success criteria, dependencies |
| STATE.md | Phase 4 sync patterns (LWW, isDirty, syncVersion) |
| Existing codebase | ReaderToolbar layout, BottomSheet patterns, theme system, Colors/Fonts constants, touch target sizing (44px), animation patterns (FadeIn/FadeOut) |
| @epubjs-react-native types | Annotation API: menuItems, onSelected, onPressAnnotation, onAddAnnotation, onChangeAnnotations, initialAnnotations, AnnotationStyles |
| Package: @gorhom/bottom-sheet | Already installed, snap point patterns from TocSheet/AppearanceSheet |

---
*Generated: 2026-04-06 | Revised: 2026-04-06*
