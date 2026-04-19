# TTS Player Redesign — Liquid Glass Pill

## Summary

Redesign the TTS audio player from a dark draggable bottom bar to an Apple liquid glass expanding pill widget. The player collapses to a single glass orb in the bottom-right corner and expands to a centered glass pill on click. Auto-dismisses after 4 seconds of mouse inattention when not playing. The chat/mic button moves from the player to the shared `ReaderToolbar`.

## Design Decision

**Approach chosen: Expanding Glass Pill (Option B)**

The collapsed orb morphs into a translucent pill capsule at bottom center. A single unified frosted glass surface with high transparency. Chosen over floating individual orbs (A) and hybrid orbs+tray (C) for superior visual cohesion and the satisfying Dynamic Island-style morph animation.

## Visual Design

### Liquid Glass Effect (CSS)

Applied to both the collapsed orb and expanded pill:

```css
background: linear-gradient(
  135deg,
  rgba(255, 255, 255, 0.32) 0%,
  rgba(255, 255, 255, 0.12) 40%,
  rgba(200, 210, 230, 0.16) 100%
);
backdrop-filter: blur(40px) saturate(180%);
border: 1px solid rgba(255, 255, 255, 0.45);
box-shadow:
  0 4px 24px rgba(0, 0, 0, 0.08),
  0 0 0 0.5px rgba(255, 255, 255, 0.3) inset,
  0 1px 0 rgba(255, 255, 255, 0.5) inset;
```

Each control button inside the pill gets its own lighter liquid glass treatment:

```css
background: linear-gradient(
  135deg,
  rgba(255, 255, 255, 0.35) 0%,
  rgba(255, 255, 255, 0.15) 100%
);
backdrop-filter: blur(20px);
border: 0.5px solid rgba(255, 255, 255, 0.35);
box-shadow:
  0 1px 4px rgba(0, 0, 0, 0.06),
  0 0.5px 0 rgba(255, 255, 255, 0.4) inset;
```

### Collapsed State (Orb)

- **Position**: Fixed, bottom-right (`bottom: 32px; right: 32px`)
- **Size**: 52x52px circle
- **Content**: 4 waveform bars (3px wide, varying heights: 8/14/20/12px)
- **Playing indicator**: Bars animate with staggered `scaleY` keyframes (0.8s, ease-in-out, infinite alternate, delays 0/0.15s/0.3s/0.45s)
- **Idle indicator**: Bars are static
- **Hover**: `scale(1.08)`, increased shadow
- **Active**: `scale(0.95)`

### Expanded State (Pill)

- **Position**: Fixed, bottom-center (`bottom: 32px; left: 50%; transform: translateX(-50%)`)
- **Shape**: Pill with `border-radius: 40px`, padding `8px 14px`
- **Controls** (left to right):
  1. **Previous** (SkipBack) — 42x42px glass circle
  2. **Play/Pause** (Play/Pause/Loader2) — 50x50px glass circle (larger, primary action)
  3. **Next** (SkipForward) — 42x42px glass circle
  4. **Stop** (Square) — 42x42px glass circle
- **Button hover**: `scale(1.06)`, brighter glass gradient
- **Button active**: `scale(0.94)`
- **Icons**: Lucide React, `rgba(0, 0, 0, 0.6)` stroke/fill, 18-22px

## Animations

### Expand (orb → pill)

- **Duration**: ~250ms
- **Easing**: `cubic-bezier(0.34, 1.56, 0.64, 1)` (spring overshoot)
- **Sequence**:
  1. Orb begins scaling up and translating from bottom-right toward bottom-center
  2. `border-radius` morphs from `50%` to `40px`
  3. Width expands from 52px to pill width
  4. Controls fade in with 50ms stagger (opacity 0→1)
  5. Waveform bars inside orb cross-fade to controls

### Collapse (pill → orb)

- **Duration**: ~200ms
- **Easing**: `ease-in-out`
- **Sequence**: Reverse of expand — controls fade out, pill contracts, slides to bottom-right

### Implementation approach

Use React state to track `expanded: boolean`. CSS transitions handle the morph via `transition: all 250ms cubic-bezier(...)`. The container element is always rendered — its position, size, and border-radius change based on state. Controls render conditionally with opacity transitions.

## Auto-Dismiss Behavior

### Timer Logic

```
State: expanded = false, dismissTimer = null

On orb click:
  → expanded = true, clear dismissTimer

On mouseenter pill area:
  → clear dismissTimer

On mouseleave pill area:
  → if playingState !== Playing:
       start 4s dismissTimer → on expire: expanded = false

On playingState change to Playing:
  → clear dismissTimer (pill stays visible)

On playingState change to Paused or Stopped:
  → if mouse is outside pill area:
       start 4s dismissTimer
```

### "Bottom zone" definition

The mouseleave/mouseenter events are on the pill element itself, not a region. The pill's padding and size provide a natural hover target. No arbitrary "bottom section" zone needed — the pill's own bounds are the interaction area.

## Component Changes

### `TTSControls.tsx` — Refactor

**Remove:**
- `Draggable` wrapper (no more free-drag positioning)
- `STORE_PATH` and position persistence logic
- `getDefaultPosition` / `getDefaultChatPosition` functions
- Chat/mic button and related state (`isChatting`, `toggleChat`, `handleChat`, `stopChat`)
- Chat overlay (the AI GIF draggable)
- `Volume2` icon (redundant — waveform communicates audio state)

**Add:**
- `expanded` state (boolean, default false)
- `dismissTimerRef` (useRef for the 4s timeout)
- Morph animation CSS (transitions on the container)
- Waveform SVG/div for collapsed state
- `onMouseEnter` / `onMouseLeave` handlers on the pill
- Auto-dismiss logic tied to `playingState`

**Keep unchanged:**
- All player logic (`handlePlay`, `handleStop`, `handlePrev`, `handleNext`)
- `useEffect` for player initialization and cleanup
- Error handling (error toast, `handleErrorClose`, `handleShowErrorDetails`)
- `useRequireAuth` for play action
- `playingState` subscription via eventBus

### `ReaderToolbar.tsx` — No changes

The toolbar component itself needs no modification. It already accepts `children` for right-side content and `leftContent` for left-side content.

### Reader components — Add mic button to toolbar children

Each reader (epub.tsx, pdf.tsx, MobiView.tsx, DjvuView.tsx) adds the mic/chat `IconButton` to their `<ReaderToolbar>` children alongside existing buttons (BackButton, BookmarkButton, etc.). The mic button uses the same `useRequireAuth` and `useChatStore` integration currently in TTSControls.

The chat overlay (AI GIF draggable) moves to the reader component level, rendered conditionally when `isChatting` is true.

### `Draggable.tsx` — No changes

Still used by the chat overlay. Not used by the player anymore.

### `IconButton.tsx` — No changes

The liquid glass styling is applied via Tailwind classes on the TTSControls buttons directly, not by modifying the shared IconButton component.

## Files Modified

| File | Change |
|------|--------|
| `src/components/TTSControls.tsx` | Major refactor — new UI, remove drag, remove mic |
| `src/components/epub.tsx` | Add mic button to ReaderToolbar children, move chat overlay here |
| `src/components/pdf/components/pdf.tsx` | Add mic button to ReaderToolbar children, move chat overlay here |
| `src/components/mobi/MobiView.tsx` | Add mic button to ReaderToolbar children, move chat overlay here |
| `src/components/djvu/DjvuView.tsx` | Add mic button to ReaderToolbar children, move chat overlay here |

## Error Handling

Error display stays in TTSControls. When errors occur, the `AlertTriangle` icon appears inside the expanded pill as an additional element after the stop button. The error toast behavior is unchanged.

## Testing Considerations

- Verify morph animation renders correctly in WebKit (Tauri uses WebKitGTK on Linux, WKWebView on macOS)
- `backdrop-filter` is well-supported in modern WebKit but verify blur renders with Tauri's webview
- Test auto-dismiss timer: mouseleave starts timer, mouseenter cancels, playing suspends
- Test mic button works correctly from its new location in ReaderToolbar
- Test chat overlay still renders and functions from reader component level
