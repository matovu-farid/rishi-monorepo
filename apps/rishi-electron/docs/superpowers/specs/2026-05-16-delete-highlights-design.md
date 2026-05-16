# Deleting Highlights (Panel Access + Inline Popover + Undoable Delete)

**Date:** 2026-05-16
**Scope:** `apps/rishi-electron`
**Approach:** Test-driven (red → green → refactor).
**Builds on:** `2026-05-16-tts-autohide-and-highlight-undo-design.md` (helper, hook, toast pattern).

## Problem

The renderer ships a complete `HighlightsPanel` with a working delete button, but no UI surface ever opens the panel — no menu item, no shortcut, no toolbar entry. The panel is dead code from the user's point of view. Even if the user reached the panel, its `handleDelete` removes the DB row but never calls `removeHighlight(rendition, cfiRange)`, so the colored mark stays drawn on the page until the book is reloaded. There is also no in-context way to delete a highlight by interacting with it directly in the text.

## Goals

- The user can open the Highlights panel via the native View menu and via `Cmd/Ctrl+Shift+H`.
- The user can click any highlighted span in the reader to open an inline popover that lets them change color, edit the note, or delete the highlight.
- Deleting a highlight (from the panel OR from the inline popover) shows a sonner toast with an Undo action and registers the same `Cmd/Ctrl+Z` shortcut slot the apply flow already uses.
- Panel-delete removes the visual mark immediately (no more reload-to-clear).

## Non-Goals

- Bulk delete from the panel.
- Undo via toast for color change or note edit. Color change has natural undo (pick another swatch); the note editor has its own Save/Cancel.
- Wiring `SelectionPopover` or the new inline popover into AZW3/PDF views — they do not render user highlights today.
- A dedicated `highlights:undelete` IPC. Re-applying via `saveHighlight` inserts a fresh row and the original soft-deleted row stays as a benign ghost. Sync semantics remain correct (`isDirty=1` on both sides of the transition).

## Architecture

Three coordinated surfaces, all sharing the existing helper + hook infrastructure from the apply flow:

```
                       View menu / Cmd+Shift+H
                                |
                                v
                       useMenuCommands wiring
                                |
                                v
                        setHighlightsPanelOpen(true) ──► HighlightsPanel
                                                              |
                                                              v
                                                       deleteHighlightWithUndo
                                                              |
Click highlighted span in reader ──► HighlightActionPopover ──┤
                                          | color / note / delete
                                          v
                                  delete → deleteHighlightWithUndo
                                  color  → swap visual + updateHighlightColor
                                  note   → NoteEditor
                                                              |
                                                              v
                              ┌──────────────────────────────┘
                              v
              Toast "Highlight deleted" with Undo
              + setLastUndoable(handle) → Cmd/Ctrl+Z slot
```

The existing `useUndoableHighlightShortcut` hook already accepts any `HighlightHandle`; the new delete helper returns the same shape, so the keyboard binding works without modification.

## Part 1 — Panel Access (Menu + Shortcut)

### Native menu

A new "View → Show Highlights" item, accelerator `CmdOrCtrl+Shift+H`. When clicked, it emits a `reader:showHighlights` IPC event over the existing main→renderer command channel (same pattern used by `reader:readAloudFromSelection`, commit `2fa737cc`).

### Preload contract & renderer subscription

Register `reader:showHighlights` in `src/preload/ipc-contract.ts` alongside the existing reader command channels. Renderer subscribes via `useMenuCommands` inside EpubView and calls `setHighlightsPanelOpen(true)`.

### Renderer-level keyboard shortcut

A global `Cmd/Ctrl+Shift+H` keydown listener mounted in `EpubView`. Same editable-target skip as the existing arrow-key and `Cmd+Z` listeners (INPUT/TEXTAREA/contentEditable). Listening at the renderer level rather than relying on the native accelerator means the shortcut still works when the EpubView is focused but the menu is not visible (e.g. macOS fullscreen with auto-hide).

The two paths (menu and shortcut) both call `setHighlightsPanelOpen(true)`. No coordination needed; the panel is idempotent on open.

## Part 2 — Inline Highlight Popover

### New file: `src/renderer/src/components/highlights/HighlightActionPopover.tsx`

Small modal-less popover, mirrors the visual language of `SelectionPopover`:

```ts
interface HighlightActionPopoverProps {
  position: { x: number; y: number }
  currentColor: HighlightColor
  onSelectColor: (color: HighlightColor) => void
  onEditNote: () => void
  onDelete: () => void
  onClose: () => void
}
```

Contents (left to right):
- Row of color swatches from `HIGHLIGHT_COLORS` — clicking one calls `onSelectColor` and closes the popover. The currently-applied color is visually marked (e.g. ring) so the user can see what they're swapping from.
- Pencil button — calls `onEditNote` and closes.
- Trash button — calls `onDelete` and closes.

Closes on outside click and Escape. Same close mechanics as `SelectionPopover`.

### Wiring the click → popover

`rendition.annotations.highlight(...)` accepts a per-annotation click callback (`cb`). EpubView currently passes `() => {}` at the `applyVisual` callsite (`EpubView.tsx:323`). Replace with a real handler that:

1. Captures the click event's position in iframe coordinates and translates to viewport coordinates (same math as `handleTextSelected` at `EpubView.tsx:307-312`).
2. Looks up the highlight row by `cfiRange` (closed over per-annotation when the callback is registered, so no lookup table is strictly required at click time). EpubView already loads all highlights on rendition-ready (`EpubView.tsx:274-282`); we extend that loop to keep a `highlightsByRangeRef: useRef<Map<string, HighlightRow>>()` so the popover can read the latest `color`/`note` after edits without forcing a re-render. A ref (not state) because the map is read inside the click callback and doesn't drive React output.
3. Opens `HighlightActionPopover` anchored to the click position with the matched row's color preselected.

The persisted-highlight load loop at `EpubView.tsx:274-282` must be extended to pass the same click callback when re-drawing on book open.

### Color change

When `onSelectColor(newColor)` fires:
- `removeHighlight(rendition, cfiRange)` — removes the existing visual.
- `highlightRange(rendition, cfiRange, ..., newHex)` — re-applies with the new color (and the same click callback, so the new visual is clickable too).
- `updateHighlightColor(highlightId, newColor)` — updates the DB row.
- `triggerWrite()` — propagates the sync.

No toast, no undo handle. If the user changes their mind, they click the highlight again and pick another color. Matches the spec's non-goal of "no undo for color change."

### Edit note

Reuse the existing `NoteEditor` component. EpubView already imports `NoteEditor` indirectly through `HighlightsPanel`; surface it at the EpubView level too, opened with the clicked highlight as its `highlight` prop. `onSaved` refreshes the in-memory highlight map.

### Delete

Calls `deleteHighlightWithUndo(...)` (new helper, Part 3). Toast appears, `Cmd/Ctrl+Z` slot is populated.

## Part 3 — Undoable Delete (Helper + Hook Reuse)

### Helper extension

Add to `src/renderer/src/modules/highlight-actions.ts`:

```ts
export interface DeleteHighlightArgs {
  target: HighlightTarget   // same interface as apply (applyVisual + removeVisual)
  bookSyncId: string
  cfiRange: string
  text: string
  color: HighlightColor
  note?: string
  chapter?: string | null
}

export async function deleteHighlightWithUndo(args: DeleteHighlightArgs): Promise<HighlightHandle>
```

Behavior:
- `target.removeVisual()` runs immediately (optimistic delete).
- `deleteHighlight(bookSyncId, cfiRange)` soft-deletes the DB row.
- `getSyncService().triggerWrite()` propagates.
- Returns a handle whose `undo()`:
  - `target.applyVisual()` — re-applies the colored mark.
  - `saveHighlight({ bookSyncId, cfiRange, text, color, note, chapter })` — re-inserts the row (DB upsert checks for *non-deleted* rows only, so this creates a fresh row; the soft-deleted ghost remains, which is fine for sync).
  - `triggerWrite()`.

Error handling matches the apply helper: errors during persistence are logged but do not prevent the handle from being returned. Visual `removeVisual`/`applyVisual` are awaited *outside* the try/catch so callers can surface visual failures explicitly.

### Hook reuse

`useUndoableHighlightShortcut` already accepts any `HighlightHandle` — no changes. Both delete sites (panel and inline popover) call `setLastUndoable(handle)` after receiving the delete handle. `Cmd/Ctrl+Z` invokes `handle.undo()` which restores the highlight.

### Panel bugfix

`HighlightsPanel.tsx`'s `handleDelete` currently:

```ts
await deleteHighlightById(highlightId)
getSyncService().triggerWrite()
await refreshHighlights()
```

Replace with a call to `deleteHighlightWithUndo`. The panel knows the row's `cfiRange`, `text`, `color`, and `note` (it has the full `HighlightRow`). Pass a `HighlightTarget` whose `removeVisual` uses the rendition prop and whose `applyVisual` re-draws via `highlightRange` (with the standard styles). After delete, register the handle with `setLastUndoable` and show the toast.

Note: this means the panel now requires `setLastUndoable` from the parent (EpubView) — pass it as a prop. Alternative is to call the hook inside the panel itself, but that creates two parallel slots, breaking the single-most-recent invariant. **Decision:** pass `setLastUndoable` down as a prop.

## Tests (will be expanded in the implementation plan)

- `HighlightActionPopover.test.tsx` — renders color swatches + pencil + trash; clicking each fires the right callback; current color is visually marked; escape/outside-click closes.
- `highlight-actions.test.ts` (extended) — `deleteHighlightWithUndo` calls `removeVisual` + `deleteHighlight` + `triggerWrite` exactly once; returned handle's `undo()` calls `applyVisual` + `saveHighlight` + `triggerWrite` once; save-failure path still returns a working handle; idempotent double-undo.
- Coverage gap acknowledged: native menu + IPC + EpubView click-callback wiring are verified by manual smoke (same as the existing read-aloud menu items). The plan will include a smoke checklist.

## Out-of-Scope (recapped, for the implementer)

- AZW3/PDF view changes.
- Bulk operations.
- Color/note undo via toast.
- `highlights:undelete` IPC.
- Reorganizing the existing `HighlightsPanel` UI — only the delete path is touched.
