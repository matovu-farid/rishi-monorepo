# PDF Highlight UI Parity with EPUB

**Date:** 2026-05-17
**Scope:** `apps/rishi-electron`
**Approach:** Test-driven (red → green → refactor), one phase per commit.

## Problem

The EPUB reader has a mature highlight UX:

- Text-selection popover with 4 color swatches, add-note, read-aloud, and (for existing highlights) delete.
- Click-on-highlight popover with color picker, edit-note, and delete.
- `NoteEditor` modal for note authoring.
- Undo for create and delete (sonner toast + `Cmd/Ctrl+Z`) via `useUndoableHighlightShortcut`.
- Persistent storage via SQLite (`highlight-storage.ts`) and the format-agnostic `applyHighlightWithUndo` / `deleteHighlightWithUndo` helpers.
- Electron context menu entry "Read Aloud From Here".

The PDF reader has none of this. Text selection in a PDF is silent — no popover, no persistence, no undo, no click-on-highlight UI. The only "highlighting" present is the TTS playback paragraph tint (`pdf-page.tsx`), which is unrelated to user-created highlights.

## Goals

- The PDF reader exposes the same user-facing highlight feature set as the EPUB reader:
  - Text-selection popover (colors, note, read-aloud, delete-when-editing).
  - Click-on-highlight popover (colors, note, delete).
  - `NoteEditor` modal.
  - Undo via toast + `Cmd/Ctrl+Z`.
  - "Read Aloud From Here" context menu.
- Persistence works: highlights survive book reopen.
- The `SelectionPopover`, `HighlightActionPopover`, `NoteEditor`, `useUndoableHighlightShortcut`, and `highlight-actions` modules are used by both readers — no duplicated UI code.
- Each phase ships with red→green tests authored before implementation.

## Non-Goals

- Multi-page text selections in v1 (selection that spans across a page boundary is dropped silently). Future work.
- Performance virtualization for books with thousands of highlights. v1 renders all visible-page highlights eagerly.
- Sync-server support for the new PDF locator fields. If the existing sync endpoint rejects unknown fields, PDF highlights remain local-only in v1 and sync support is a follow-up.
- Rotated PDF pages are not specifically tested; coordinate math relies on pdfjs's `PageViewport` transforms which already handle rotation, but no regression test covers it in v1.

## Architecture Overview

Existing layers re-used unchanged or with minimal extension:

| Module | Status |
|---|---|
| `types/highlight.ts` (palette, hex helpers) | re-use |
| `components/highlights/SelectionPopover.tsx` | re-use (already format-agnostic per the explorer survey) |
| `components/highlights/HighlightActionPopover.tsx` | re-use |
| `components/highlights/NoteEditor.tsx` | re-use |
| `hooks/useUndoableHighlightShortcut.ts` | re-use |
| `modules/highlight-actions.ts` (apply/delete with undo) | re-use |
| `modules/highlight-storage.ts` | extend (schema discriminator + locator column) |

New PDF-specific modules:

| Module | Purpose |
|---|---|
| `modules/pdf-locator.ts` | Pure conversion between DOM `Range` ↔ `PdfLocator` JSON, and `PdfLocator` → screen rects for overlay rendering |
| `hooks/usePdfTextSelection.ts` | Observes the PDF container for non-collapsed selections; emits `{locator, anchorPos}` |
| `components/pdf/HighlightLayer.tsx` | Renders per-page overlay rects for saved highlights; click bubbles row + mouse event to host |

`PdfView` (existing) is extended to host the popovers, modal, and undo wiring — mirroring `EpubView`'s pattern.

## Data Model

`HighlightRow` is extended with two columns:

```ts
type HighlightRow = {
  id: string
  bookId: string
  format: 'epub' | 'pdf'    // NEW — discriminator
  cfiRange: string | null    // EPUB only
  locator: string | null     // NEW — PDF JSON-encoded
  text: string
  color: HighlightColor
  note: string | null
  chapter: string | null
  createdAt: number
  syncId: string | null
  isDirty: 0 | 1
  isDeleted: 0 | 1
}
```

PDF locator JSON shape:

```ts
type PdfLocator = {
  page: number          // 1-indexed PDF page
  rects: Array<{        // PDF coord space (bottom-left origin), zoom-independent
    x: number
    y: number
    w: number
    h: number
  }>
}
```

**Migration:** SQLite `ALTER TABLE` adds `format` (default `'epub'`) and `locator` (nullable). Existing EPUB rows are unaffected.

**Query path:** read queries that load highlights for a book remain format-agnostic (return all rows for the book). Format-specific filtering happens in the renderer (EPUB consumes `cfiRange`, PDF consumes `locator`).

## PDF Locator Math (`modules/pdf-locator.ts`)

Two pure functions, both unit-tested:

```ts
selectionToPdfLocator(
  range: Range,
  pageEl: HTMLElement,           // .react-pdf__Page node containing the selection
  viewport: PageViewport,        // pdfjs viewport at current zoom
  pageNumber: number,
): PdfLocator | null              // null if selection spans pages or is empty

pdfLocatorToScreenRects(
  locator: PdfLocator,
  pageEl: HTMLElement,
  viewport: PageViewport,
): Array<{ left: number; top: number; width: number; height: number }>
```

Implementation uses `viewport.convertToPdfPoint(x, y)` for forward conversion and `viewport.convertToViewportPoint(pdfX, pdfY)` for reverse. PDF coords use bottom-left origin; viewport uses top-left — handled inside the helpers. Tests assert **orientation correctness** (not just round-trip — a symmetric bug would round-trip cleanly).

Cross-page guard: if `range.startContainer` and `range.endContainer` resolve to different `.react-pdf__Page` ancestors, `selectionToPdfLocator` returns `null`.

## Selection Detection (`hooks/usePdfTextSelection.ts`)

```ts
usePdfTextSelection({
  containerRef,                  // PdfView scroll container
  getPageElement: (n) => HTMLElement | null,
  getViewport: (n) => PageViewport | null,
  onSelect: (sel: { locator: PdfLocator; anchorPos: {x, y} }) => void,
  onClear: () => void,
})
```

Listens to `mouseup` and `selectionchange` on the container. On `mouseup` with a non-collapsed selection, walks the start container's ancestors to find the page element, looks up its page number and viewport, calls `selectionToPdfLocator`, and surfaces an `anchorPos` (top-center of the first client rect, in `clientX/clientY` space — matches the `position: fixed` positioning model the popovers already use).

`onClear` fires when the selection becomes collapsed (e.g., user clicks elsewhere).

## Highlight Overlay (`components/pdf/HighlightLayer.tsx`)

One instance per visible page, rendered alongside `<Page>`:

```tsx
<HighlightLayer
  pageNumber={n}
  pageEl={pageEl}
  viewport={viewport}
  highlights={pdfHighlightsForPage}
  onHighlightClick={(row, mouseEvent) => ...}
/>
```

Behavior:

- One absolutely-positioned `<div>` per rect, sized via `pdfLocatorToScreenRects`.
- Container: `pointer-events: none`. Rect divs: `pointer-events: auto`. This lets non-highlighted regions of the page remain text-selectable while still making rects clickable.
- Background color: the row's `HIGHLIGHT_COLORS[c]` hex at ~35% alpha (visual weight matches EPUB's epubjs annotations).
- Rect click → `onHighlightClick(row, mouseEvent)`. Host computes a `clientX/clientY` anchor and opens `HighlightActionPopover`.
- Re-renders automatically when `viewport` prop changes (zoom).

## PdfView Integration

Mirror `EpubView`'s state:

- `selectionPopover: { locator, anchorPos } | null`
- `inlinePopover: { rowId, anchorPos } | null`
- `editingNoteRow: HighlightRow | null`
- `lastUndoable: HighlightHandle | null` → `useUndoableHighlightShortcut(lastUndoable)`
- Memoized `highlightsByPage: Map<number, HighlightRow[]>` from `format='pdf'` rows for the current book.

Flows:

1. **Create from selection.** `usePdfTextSelection` → set `selectionPopover` → `SelectionPopover` renders with the configured color row, the add-note button, and (when TTS is available for PDFs) the Read Aloud button — identical surface to the EPUB call site. Clicking a color → `applyHighlightWithUndo({ format: 'pdf', bookId, locator, text, color, target })`. `target.applyVisual` / `removeVisual` are no-ops (store is the source of truth; overlay re-renders from store). Handle stored in `lastUndoable`; sonner toast shows "Highlight added · Undo".
2. **Click existing highlight.** `HighlightLayer` overlay click → set `inlinePopover` → user picks color (update row), edits note (open `NoteEditor`), or deletes (`deleteHighlightWithUndo` → undo toast).
3. **Undo.** `useUndoableHighlightShortcut` wired at the reader root so `Cmd/Ctrl+Z` works for whichever reader is active.
4. **Escape / outside click.** Same 100 ms outside-click delay used by the EPUB popovers (already in the shared components).
5. **Electron "Read Aloud From Here".** PdfView registers the existing `reader:readAloudFromSelection` IPC listener; on dispatch it reads the current selection, computes a start point for TTS, and starts playback.

## Build Order

| # | Phase | Test surface |
|---|---|---|
| 1 | Extend `HighlightRow` schema + DB migration | round-trip serialization, migration on existing EPUB rows, queries return both formats |
| 2 | `pdf-locator.ts` — `selectionToPdfLocator`, `pdfLocatorToScreenRects` | orientation correctness, round-trip across simulated zoom, cross-page guard returns null |
| 3 | `usePdfTextSelection` hook | fires `onSelect` on mouseup with valid locator; drops cross-page; clears on collapse |
| 4 | `HighlightLayer` overlay | one div per rect; color applied; click invokes handler with row; re-renders on viewport change |
| 5 | `SelectionPopover` wired in PdfView | selection → popover; color click → row created + undo toast |
| 6 | `HighlightActionPopover` wired in PdfView | overlay click → popover; color change persists; delete + `Cmd-Z` undo |
| 7 | `NoteEditor` wired in PdfView | edit-note opens modal; save persists; discard reverts |
| 8 | Electron context menu wiring | "Read Aloud From Here" IPC routes to PdfView when PDF is active |
| 9 | Manual UAT in dev server | smoke test all flows end-to-end |

Each phase = one commit. Tests are red before implementation.

## Agent Team Mapping

| Role | Tool agent | Responsibility |
|---|---|---|
| test-planner | `feature-dev:code-architect` | Per phase, design the test cases (fixtures, assertions, edge cases) before any test is written |
| tester | `general-purpose` | Write failing tests per the test plan |
| test-reviewer | `feature-dev:code-reviewer` | Review tests for coverage gaps, weak assertions, fake mocks |
| code-planner | `feature-dev:code-architect` | Design the implementation (files, signatures, integration points) to make the tests pass |
| coder | `general-purpose` | Write the implementation |
| code-reviewer | `feature-dev:code-reviewer` | Review implementation for correctness, conventions, security, and adherence to the spec |

Per-phase workflow: test-plan → test-plan-review → tests written (red) → test-review → code-plan → code (green) → code-review → commit.

The orchestrator (the lead session) dispatches each agent and keeps state.

## Risks

- **pdfjs viewport orientation.** PDF coords are bottom-left origin; CSS top-left. Tests must assert orientation explicitly — a symmetric bug would pass round-trip.
- **Text-layer DOM churn.** react-pdf re-creates the text layer on zoom and on some state updates. Overlay must not depend on text-layer node identity — it anchors to the page element and viewport only.
- **Sync field tolerance.** New `format` / `locator` fields may be rejected by the existing sync server. If so, PDF highlights remain local-only in v1 (DB rows still saved); server work is a follow-up.
- **Selection / overlay pointer-events conflict.** Overlay rects must allow selection on non-highlighted regions. Validated in dev-server smoke (phase 9).
- **Performance with many highlights.** v1 renders all per-page rects eagerly. Acceptable for typical books; virtualization deferred.

## Testing Strategy

- **Unit tests** (vitest) for pure modules: `pdf-locator.ts`, schema serialization, `usePdfTextSelection`, `HighlightLayer`.
- **Component tests** (vitest + React Testing Library) colocated with components: popover wiring, PdfView integration flows for create/edit/delete/undo.
- **Manual UAT** in dev server for the final integration — type-check and unit pass do not certify UX correctness.

All work follows the repo TDD convention (red → green → refactor).
