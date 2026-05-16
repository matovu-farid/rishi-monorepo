# TTS Pill Auto-Hide Fix & Undoable Highlights

**Date:** 2026-05-16
**Scope:** `apps/rishi-electron`
**Approach:** Test-driven (red → green → refactor).

## Problem

Two related reader UX regressions:

1. The TTS controls "pill" auto-collapses to its orb form during active playback whenever the player passes through a non-`playing` state (`loading`, `pageNavigating`, `republishingParagraphs`, `waitingForParagraphs`) for ≥4 s. Once collapsed it never re-expands because the dismiss effect bails when `!expanded`.
2. Applying a highlight from `SelectionPopover` is irreversible from the UI — there is no undo affordance, no keyboard shortcut, and the popover closes immediately on color pick.

## Goals

- TTS pill stays expanded for the entire active-playback session, regardless of intermediate state transitions. Paused / stopped / idle / error still collapse after 4 s — that's deliberate.
- Highlight application returns an undo handle. The handle is reachable via a sonner toast and via `Cmd/Ctrl+Z`.
- Undo path is format-agnostic — adding user highlights to AZW3/PDF later inherits undo for free.

## Non-Goals

- Wiring `SelectionPopover` into AZW3 or PDF views. They have no user-applied highlight flow today; this spec only ensures the undo helper is shaped so a future format can adopt it.
- Multi-step undo stack. A single most-recent-highlight slot is enough — matches the toast's lifetime.
- Reassigning the highlight color via undo+redo. Color changes already have their own path (`updateHighlightColor`).

## Part 1 — TTS Pill: Don't Auto-Collapse During Active Playback

### Root Cause

`TTSControls.tsx:46-56`:

```ts
useEffect(() => {
  if (!expanded) return
  if (playingState === 'playing') {
    clearDismissTimer()
  } else if (!isHoveringRef.current) {
    startDismissTimer()
  }
}, [playingState, expanded, clearDismissTimer, startDismissTimer])
```

Only `'playing'` is treated as active. Every transient state (`loading`, `pageNavigating`, `republishingParagraphs`, `waitingForParagraphs`) re-arms the 4 s dismiss timer. Slow TTS bootstrap or a long page turn collapses the pill mid-session; subsequent return to `'playing'` does not re-open it because the effect early-returns on `!expanded`.

### Fix

Introduce a constant `ACTIVE_PLAYBACK_STATES` and use it in the effect:

```ts
const ACTIVE_PLAYBACK_STATES: ReadonlySet<PlayerStoreState> = new Set([
  'loading',
  'playing',
  'waitingForParagraphs',
  'pageNavigating',
  'republishingParagraphs'
])

useEffect(() => {
  if (!expanded) return
  if (ACTIVE_PLAYBACK_STATES.has(playingState)) clearDismissTimer()
  else if (!isHoveringRef.current) startDismissTimer()
}, [playingState, expanded, clearDismissTimer, startDismissTimer])
```

Update the `handleMouseLeave` guard for consistency: `if (expanded && !ACTIVE_PLAYBACK_STATES.has(playingState)) startDismissTimer()`.

### Tests (new `TTSControls.test.tsx`, RTL + `vi.useFakeTimers`)

1. **Stuck in `loading` ≥4 s** — pill expanded, state stays `loading`, advance fake timers by 5 s → pill remains expanded.
2. **Transient `pageNavigating` during playback** — sequence `playing → pageNavigating (5 s) → playing` → pill remains expanded throughout.
3. **`paused.clean` ≥4 s** (regression guard) — pill auto-collapses to orb.
4. **`idle` after orb click** (regression guard) — never played, advance 5 s → collapses.

## Part 2 — Highlight Undo

### Helper Module

New file: `src/renderer/src/modules/highlight-actions.ts`.

```ts
export interface HighlightTarget {
  applyVisual: () => Promise<void> | void
  removeVisual: () => Promise<void> | void
}

export interface ApplyHighlightArgs {
  target: HighlightTarget
  bookSyncId: string
  cfiRange: string            // identifier — EPUB uses CFI; PDF/AZW3 supply their own opaque id
  text: string
  color: HighlightColor
}

export interface HighlightHandle {
  undo: () => Promise<void>
}

export async function applyHighlightWithUndo(args: ApplyHighlightArgs): Promise<HighlightHandle>
```

Behavior:

- `applyVisual()` runs immediately (optimistic).
- `saveHighlight(...)` persists; on failure logs to console (matches existing behavior at `EpubView.tsx:335`) and still returns a handle whose `undo()` removes the visual.
- `triggerWrite()` on the sync service is called after save.
- `undo()` calls `removeVisual()` + `deleteHighlight(bookSyncId, cfiRange)` + `triggerWrite()`. All three operations are idempotent (verified — `removeHighlight` in `epubjs-extensions` is a no-op when the CFI isn't drawn; `deleteHighlight` does a keyed delete).

### EpubView Integration

Replace the inline body of `handleHighlightColor` (`EpubView.tsx:319-340`) with:

```ts
const handle = await applyHighlightWithUndo({
  target: {
    applyVisual: () => highlightRange(rendition, selectionInfo.cfiRange, {}, () => {}, 'epubjs-hl', { fill: hex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply' }),
    removeVisual: () => removeHighlight(rendition, selectionInfo.cfiRange)
  },
  bookSyncId: bookSyncIdRef.current,
  cfiRange: selectionInfo.cfiRange,
  text: selectionInfo.text,
  color
})
lastUndoableHighlightRef.current = handle
toast('Highlighted', {
  action: { label: 'Undo', onClick: () => void handle.undo() },
  duration: UNDO_WINDOW_MS,
  onDismiss: () => { if (lastUndoableHighlightRef.current === handle) lastUndoableHighlightRef.current = null },
  onAutoClose: () => { if (lastUndoableHighlightRef.current === handle) lastUndoableHighlightRef.current = null }
})
```

`UNDO_WINDOW_MS = 5_000` — same as the sonner default, kept as a named constant so the keyboard shortcut and toast share it.

### Keyboard Shortcut

A new `useLastUndoableHighlight` hook (small module-level ref + setter) and a global keydown listener inside `EpubView`:

- On `Cmd+Z` (mac) or `Ctrl+Z` (win/linux), no other modifiers:
  - Skip if target is `INPUT`, `TEXTAREA`, or `contentEditable` (mirrors the arrow-key guard in `TTSControls.tsx:65-82`).
  - If `lastUndoableHighlightRef.current` is non-null: `preventDefault()`, invoke `undo()`, clear the slot.
  - Otherwise fall through (don't preventDefault — let the OS/browser handle it).

The ref lives in the helper module so that adding a `SelectionPopover` to AZW3/PDF later just means each view registers its handle through the same hook; the shortcut listener can be lifted to a shared component if more than one view needs it.

### Tests

**`highlight-actions.test.ts` (new):**

5. `applyHighlightWithUndo` calls `applyVisual`, `saveHighlight`, `triggerWrite` exactly once on apply.
6. Returned `handle.undo()` calls `removeVisual`, `deleteHighlight`, `triggerWrite` exactly once.
7. Calling `handle.undo()` twice is safe (second call is a no-op via idempotent target ops — assert via mock call counts).
8. `saveHighlight` rejection logs a warning but still returns a working handle.

**`EpubView` integration (new — focused test, not full reader render):**

9. Toast "Undo" button calls the helper's `undo` (mock `applyHighlightWithUndo`).
10. `Cmd+Z` within `UNDO_WINDOW_MS` calls `undo`; outside the window is a no-op.
11. `Cmd+Z` while focused in an `<input>` is a no-op.
12. Toast auto-close clears the undo slot — subsequent `Cmd+Z` is a no-op.

## Architecture Notes

- The helper sits beside the existing `highlight-storage.ts` module — the visual layer is injected, so the helper never imports `epubjs` directly. This keeps the format coupling at the call site only.
- `lastUndoableHighlightRef` is intentionally a single-slot ring, not a stack. Highlight UX expectation is "undo the thing I just did" — a deeper history would invite mis-undoing old highlights via stray keypresses.
- Save-failure-but-visual-applied: leaves the on-screen mark but no row in storage. Undo still removes the visual cleanly; no orphaned DB row. Matches the existing best-effort save semantics.

## Out of Scope

- Adding user-highlight flows to AZW3/PDF views — they have no `SelectionPopover` wiring today. The helper signature is designed to drop in when those views adopt highlights.
- Redo (`Cmd+Shift+Z`). Out of current scope; the helper handle is single-use.
- Persisting the "last undoable" slot across navigation. If the user leaves the reader view, the ref clears and the undo slot is gone — matches the toast's lifecycle.
