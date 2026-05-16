# TTS Pill Auto-Hide Fix & Undoable Highlights — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the TTS controls pill from auto-collapsing mid-playback, and give the user an Undo path (toast + `Cmd/Ctrl+Z`) for highlights applied via `SelectionPopover`.

**Architecture:** A new format-agnostic helper `applyHighlightWithUndo` wraps the apply→save→sync sequence and returns an `undo` handle. A small hook `useUndoableHighlightShortcut` keeps the most-recent handle in a single-slot ref and binds `Cmd/Ctrl+Z`. The TTS pill widens its "active playback" check to all in-flight player states.

**Tech Stack:** React 18, Vitest + happy-dom + `@testing-library/react`, Zustand, sonner toasts, epubjs.

**Spec:** `docs/superpowers/specs/2026-05-16-tts-autohide-and-highlight-undo-design.md`

**Working directory for all commands:** `apps/rishi-electron/` (the package root).

---

## File Map

**Created:**
- `src/renderer/src/modules/highlight-actions.ts` — `applyHighlightWithUndo` helper.
- `src/renderer/src/modules/highlight-actions.test.ts` — helper unit tests.
- `src/renderer/src/hooks/useUndoableHighlightShortcut.ts` — single-slot ref + `Cmd/Ctrl+Z` keydown.
- `src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx` — hook tests.
- `src/renderer/src/components/tts/TTSControls.test.tsx` — pill auto-hide tests.

**Modified:**
- `src/renderer/src/components/tts/TTSControls.tsx` — add `ACTIVE_PLAYBACK_STATES`; use in dismiss effect and `handleMouseLeave`.
- `src/renderer/src/components/epub/EpubView.tsx` — replace inline highlight save with helper; wire toast and `useUndoableHighlightShortcut`.

---

## Task 1: Add failing test — pill stays expanded while stuck in `loading`

**Files:**
- Create: `src/renderer/src/components/tts/TTSControls.test.tsx`

- [ ] **Step 1: Write the failing test file**

Create `src/renderer/src/components/tts/TTSControls.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'
import { useTutorialStore } from '@/stores/tutorialStore'

vi.mock('@/hooks/usePlayerMachine', () => ({
  usePlayerMachine: () => ({ send: vi.fn() })
}))
vi.mock('@/hooks/useRequireAuth', () => ({
  useRequireAuth: () => ({ requireAuth: (_: string, cb: () => void) => cb(), AuthDialog: null })
}))
vi.mock('@/components/tutorial/ContextualHint', () => ({
  ContextualHint: ({ children }: { children: React.ReactNode }) => <>{children}</>
}))

// Import after mocks so the component picks them up.
import TTSControls from './TTSControls'

function setPlayingState(state: Parameters<typeof usePlayerStore.setState>[0]) {
  act(() => {
    usePlayerStore.setState(state)
  })
}

beforeEach(() => {
  vi.useFakeTimers()
  useTutorialStore.setState({ tourActive: false, tourCompleted: true, hintsShown: {} } as never)
  usePlayerStore.setState({ playingState: 'idle' })
})

afterEach(() => {
  vi.useRealTimers()
})

describe('TTSControls auto-collapse', () => {
  it('keeps the pill expanded when player is stuck in loading for longer than the dismiss window', () => {
    render(<TTSControls bookId="b1" />)

    // Expand the pill via the orb.
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })
    setPlayingState({ playingState: 'loading' })

    // Advance well past the 4s dismiss window.
    act(() => {
      vi.advanceTimersByTime(5_000)
    })

    expect(screen.getByLabelText('Play')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pnpm test -- src/renderer/src/components/tts/TTSControls.test.tsx`
Expected: FAIL — `Unable to find a label "Play"` (the pill has collapsed back to the orb).

- [ ] **Step 3: Commit the failing test**

```bash
git add src/renderer/src/components/tts/TTSControls.test.tsx
git commit -m "test(tts): pill collapses mid-loading (failing red test)"
```

---

## Task 2: Make the test pass — widen the active-playback check

**Files:**
- Modify: `src/renderer/src/components/tts/TTSControls.tsx` (lines 6, 14-16, 46-56, 90-95)

- [ ] **Step 1: Add the constant near the top of the file**

In `TTSControls.tsx`, change the import on line 6 from:

```ts
import { usePlayerStore } from '@/stores/playerStore'
```

to:

```ts
import { usePlayerStore, type PlayerStoreState } from '@/stores/playerStore'
```

Then, immediately after the existing `AUTO_DISMISS_MS` constant on line 15, add:

```ts
/** Player states that represent an active playback session — the pill must
 *  not auto-collapse while in any of these. Idle / stopped / paused / error
 *  still auto-collapse (intentional). */
const ACTIVE_PLAYBACK_STATES: ReadonlySet<PlayerStoreState> = new Set([
  'loading',
  'playing',
  'waitingForParagraphs',
  'pageNavigating',
  'republishingParagraphs'
])
```

- [ ] **Step 2: Replace the dismiss effect**

Replace lines 46-56 (the `useEffect` that manages the dismiss timer) with:

```ts
  // When playingState changes, manage auto-dismiss timer.
  // While in any active-playback state we suspend the timer; otherwise we
  // start it (unless the user is hovering).
  useEffect(() => {
    if (!expanded) return
    if (ACTIVE_PLAYBACK_STATES.has(playingState)) {
      clearDismissTimer()
    } else if (!isHoveringRef.current) {
      startDismissTimer()
    }
  }, [playingState, expanded, clearDismissTimer, startDismissTimer])
```

- [ ] **Step 3: Tighten `handleMouseLeave` for parity**

Replace the existing `handleMouseLeave` (lines 90-95) with:

```ts
  const handleMouseLeave = () => {
    isHoveringRef.current = false
    if (expanded && !ACTIVE_PLAYBACK_STATES.has(playingState)) {
      startDismissTimer()
    }
  }
```

- [ ] **Step 4: Run the failing test — confirm green**

Run: `pnpm test -- src/renderer/src/components/tts/TTSControls.test.tsx`
Expected: PASS.

- [ ] **Step 5: Run typecheck**

Run: `pnpm typecheck:web`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/components/tts/TTSControls.tsx
git commit -m "fix(tts): keep pill expanded for all active playback states"
```

---

## Task 3: Add regression tests for paused and idle (collapse must still happen)

**Files:**
- Modify: `src/renderer/src/components/tts/TTSControls.test.tsx`

- [ ] **Step 1: Append three regression tests inside the existing `describe` block**

After the existing test in `TTSControls.test.tsx`, add:

```tsx
  it('keeps the pill expanded across playing → pageNavigating → playing', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    setPlayingState({ playingState: 'playing' })
    act(() => vi.advanceTimersByTime(2_000))
    setPlayingState({ playingState: 'pageNavigating' })
    act(() => vi.advanceTimersByTime(5_000)) // > AUTO_DISMISS_MS
    setPlayingState({ playingState: 'playing' })

    expect(screen.getByLabelText('Pause')).toBeInTheDocument()
  })

  it('auto-collapses 4s after entering paused.clean', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    setPlayingState({ playingState: 'paused.clean' })
    act(() => vi.advanceTimersByTime(4_000))

    expect(screen.queryByLabelText('Pause')).toBeNull()
    expect(screen.queryByLabelText('Play')).toBeNull()
    expect(screen.getByRole('button', { name: /expand tts controls/i })).toBeInTheDocument()
  })

  it('auto-collapses 4s after orb click while idle', () => {
    render(<TTSControls bookId="b1" />)
    act(() => {
      screen.getByRole('button', { name: /expand tts controls/i }).click()
    })

    act(() => vi.advanceTimersByTime(4_000))

    expect(screen.getByRole('button', { name: /expand tts controls/i })).toBeInTheDocument()
  })
```

- [ ] **Step 2: Run the file**

Run: `pnpm test -- src/renderer/src/components/tts/TTSControls.test.tsx`
Expected: all four tests PASS.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/components/tts/TTSControls.test.tsx
git commit -m "test(tts): regression guards for paused/idle auto-collapse"
```

---

## Task 4: Helper apply path — failing test

**Files:**
- Create: `src/renderer/src/modules/highlight-actions.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/modules/highlight-actions.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

vi.mock('@/modules/highlight-storage', () => ({
  saveHighlight: vi.fn().mockResolvedValue('hl-1'),
  deleteHighlight: vi.fn().mockResolvedValue(undefined)
}))

vi.mock('@/services', () => ({
  getSyncService: () => ({ triggerWrite: vi.fn() })
}))

import { saveHighlight, deleteHighlight } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import { applyHighlightWithUndo } from './highlight-actions'

function makeTarget() {
  return {
    applyVisual: vi.fn(),
    removeVisual: vi.fn()
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('applyHighlightWithUndo — apply path', () => {
  it('calls applyVisual, saveHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run and confirm failure**

Run: `pnpm test -- src/renderer/src/modules/highlight-actions.test.ts`
Expected: FAIL — `Cannot find module './highlight-actions'`.

- [ ] **Step 3: Commit the red test**

```bash
git add src/renderer/src/modules/highlight-actions.test.ts
git commit -m "test(highlight-actions): apply path (red)"
```

---

## Task 5: Implement the helper apply path (green)

**Files:**
- Create: `src/renderer/src/modules/highlight-actions.ts`

- [ ] **Step 1: Write the module**

Create `src/renderer/src/modules/highlight-actions.ts`:

```ts
import { saveHighlight, deleteHighlight } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import type { HighlightColor } from '@/types/highlight'

/**
 * The visual side of a highlight — apply and remove. Injected so this
 * module does not depend on epubjs (or any future format's renderer).
 */
export interface HighlightTarget {
  applyVisual: () => Promise<void> | void
  removeVisual: () => Promise<void> | void
}

export interface ApplyHighlightArgs {
  target: HighlightTarget
  bookSyncId: string
  cfiRange: string
  text: string
  color: HighlightColor
}

export interface HighlightHandle {
  undo: () => Promise<void>
}

/**
 * Apply a highlight optimistically and return a handle whose `undo()`
 * removes both the visual mark and the persisted row. Save errors are
 * logged but do not prevent the handle from being returned — the on-screen
 * mark is already drawn, so undo must still be able to remove it.
 */
export async function applyHighlightWithUndo(args: ApplyHighlightArgs): Promise<HighlightHandle> {
  const { target, bookSyncId, cfiRange, text, color } = args

  await target.applyVisual()

  try {
    await saveHighlight({ bookSyncId, cfiRange, text, color })
    getSyncService().triggerWrite()
  } catch (err) {
    console.warn('[highlight] save failed:', err)
  }

  return {
    async undo() {
      await target.removeVisual()
      try {
        await deleteHighlight(bookSyncId, cfiRange)
        getSyncService().triggerWrite()
      } catch (err) {
        console.warn('[highlight] delete failed:', err)
      }
    }
  }
}
```

- [ ] **Step 2: Run the test — confirm green**

Run: `pnpm test -- src/renderer/src/modules/highlight-actions.test.ts`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/modules/highlight-actions.ts
git commit -m "feat(highlight): applyHighlightWithUndo helper — apply path"
```

---

## Task 6: Undo path — failing test then green

**Files:**
- Modify: `src/renderer/src/modules/highlight-actions.test.ts`

- [ ] **Step 1: Add the undo test inside the existing file**

Append a new `describe` block to `src/renderer/src/modules/highlight-actions.test.ts`:

```ts
describe('applyHighlightWithUndo — undo path', () => {
  it('handle.undo() calls removeVisual, deleteHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow'
    })

    // Reset counts so we only see undo-time activity.
    target.applyVisual.mockClear()
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-2', 'cfi:2')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if saveHighlight rejects', async () => {
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('boom'))
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    await handle.undo()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still removes visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
  })
})
```

- [ ] **Step 2: Run — all should pass against the helper from Task 5**

Run: `pnpm test -- src/renderer/src/modules/highlight-actions.test.ts`
Expected: PASS (the helper already supports these contracts).

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/modules/highlight-actions.test.ts
git commit -m "test(highlight-actions): undo, save-failure, idempotent paths"
```

---

## Task 7: Hook — failing test for `setLastUndoable` + `consume`

**Files:**
- Create: `src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx`:

```tsx
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import {
  useUndoableHighlightShortcut,
  UNDO_WINDOW_MS
} from './useUndoableHighlightShortcut'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

function makeHandle(undo = vi.fn().mockResolvedValue(undefined)) {
  return { undo }
}

describe('useUndoableHighlightShortcut', () => {
  it('Cmd+Z within the window invokes the stored handle and clears the slot', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()

    act(() => {
      result.current.setLastUndoable(handle)
    })

    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true }))
    })

    expect(handle.undo).toHaveBeenCalledTimes(1)

    // Second press: slot was cleared, no further undo.
    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true }))
    })
    expect(handle.undo).toHaveBeenCalledTimes(1)
  })

  it('Ctrl+Z also triggers undo (windows/linux)', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()

    act(() => {
      result.current.setLastUndoable(handle)
    })
    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', ctrlKey: true }))
    })
    expect(handle.undo).toHaveBeenCalledTimes(1)
  })

  it('expires the slot after UNDO_WINDOW_MS', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()

    act(() => {
      result.current.setLastUndoable(handle)
    })
    act(() => {
      vi.advanceTimersByTime(UNDO_WINDOW_MS + 100)
    })
    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true }))
    })

    expect(handle.undo).not.toHaveBeenCalled()
  })

  it('ignores Cmd+Z when focus is in an input', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()
    const input = document.createElement('input')
    document.body.appendChild(input)
    input.focus()

    act(() => {
      result.current.setLastUndoable(handle)
    })
    act(() => {
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }))
    })

    expect(handle.undo).not.toHaveBeenCalled()
    document.body.removeChild(input)
  })

  it('clearLastUndoable() empties the slot so subsequent Cmd+Z is a no-op', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()

    act(() => {
      result.current.setLastUndoable(handle)
      result.current.clearLastUndoable()
    })
    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true }))
    })
    expect(handle.undo).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run — confirm failure**

Run: `pnpm test -- src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx`
Expected: FAIL — `Cannot find module './useUndoableHighlightShortcut'`.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx
git commit -m "test(highlight-shortcut): single-slot ref + Cmd/Ctrl+Z (red)"
```

---

## Task 8: Implement `useUndoableHighlightShortcut` (green)

**Files:**
- Create: `src/renderer/src/hooks/useUndoableHighlightShortcut.ts`

- [ ] **Step 1: Write the hook**

Create `src/renderer/src/hooks/useUndoableHighlightShortcut.ts`:

```ts
import { useCallback, useEffect, useRef } from 'react'
import type { HighlightHandle } from '@/modules/highlight-actions'

/** Time after which a stored undo handle expires and `Cmd/Ctrl+Z` no
 *  longer triggers it. Matches the highlight toast's default duration. */
export const UNDO_WINDOW_MS = 5_000

interface Slot {
  handle: HighlightHandle
  timer: ReturnType<typeof setTimeout>
}

export interface UndoableHighlightShortcut {
  /** Replace the currently undoable highlight (single-slot ring). */
  setLastUndoable: (handle: HighlightHandle) => void
  /** Clear the slot — e.g. when the toast auto-closes or is dismissed. */
  clearLastUndoable: () => void
}

function isEditableTarget(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false
  if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return true
  return el.isContentEditable
}

export function useUndoableHighlightShortcut(): UndoableHighlightShortcut {
  const slotRef = useRef<Slot | null>(null)

  const clearLastUndoable = useCallback(() => {
    if (slotRef.current) {
      clearTimeout(slotRef.current.timer)
      slotRef.current = null
    }
  }, [])

  const setLastUndoable = useCallback(
    (handle: HighlightHandle) => {
      clearLastUndoable()
      const timer = setTimeout(() => {
        slotRef.current = null
      }, UNDO_WINDOW_MS)
      slotRef.current = { handle, timer }
    },
    [clearLastUndoable]
  )

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key !== 'z' && e.key !== 'Z') return
      // Cmd on mac, Ctrl elsewhere. Reject any other modifier combination
      // (e.g. Cmd+Shift+Z, which is a future redo binding).
      const isUndo = (e.metaKey && !e.ctrlKey) || (e.ctrlKey && !e.metaKey)
      if (!isUndo || e.altKey || e.shiftKey) return
      if (isEditableTarget(e.target)) return

      const slot = slotRef.current
      if (!slot) return

      e.preventDefault()
      slotRef.current = null
      clearTimeout(slot.timer)
      void slot.handle.undo()
    }

    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => clearLastUndoable, [clearLastUndoable])

  return { setLastUndoable, clearLastUndoable }
}
```

- [ ] **Step 2: Run the failing tests — confirm green**

Run: `pnpm test -- src/renderer/src/hooks/useUndoableHighlightShortcut.test.tsx`
Expected: all five tests PASS.

- [ ] **Step 3: Typecheck**

Run: `pnpm typecheck:web`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/src/hooks/useUndoableHighlightShortcut.ts
git commit -m "feat(highlight): useUndoableHighlightShortcut — toast/shortcut undo slot"
```

---

## Task 9: Wire helper + hook + toast into `EpubView`

**Files:**
- Modify: `src/renderer/src/components/epub/EpubView.tsx` (imports near top; `handleHighlightColor` at lines 319-340)

- [ ] **Step 1: Update imports**

In `EpubView.tsx`, change the import block:

- Line 22, replace:

```ts
import { saveHighlight, getHighlightsForBook } from '@/modules/highlight-storage'
```

with:

```ts
import { getHighlightsForBook } from '@/modules/highlight-storage'
import { applyHighlightWithUndo } from '@/modules/highlight-actions'
```

- After the existing `useSelectionStore` import on line 45, add:

```ts
import { useUndoableHighlightShortcut } from '@/hooks/useUndoableHighlightShortcut'
```

Note: `saveHighlight` and `getSyncService` callers elsewhere in this file (currently around lines 671 and 804) are untouched — they belong to a different code path. Only the inline body of `handleHighlightColor` moves into the helper.

- [ ] **Step 2: Use the hook inside the component**

After the existing `useEpubStore`/`useState` hook calls near the top of the `EpubView` component body (look for `const [highlightsPanelOpen, setHighlightsPanelOpen] = useState(false)` around line 192), add:

```ts
  const { setLastUndoable } = useUndoableHighlightShortcut()
```

- [ ] **Step 3: Replace `handleHighlightColor`**

Replace the entire `handleHighlightColor` callback (currently lines 319-340) with:

```ts
  const handleHighlightColor = useCallback(
    (color: HighlightColor) => {
      if (!selectionInfo || !rendition || !bookSyncIdRef.current) return
      const hex = getHighlightHex(color)
      const cfiRange = selectionInfo.cfiRange
      const text = selectionInfo.text
      const bookSyncId = bookSyncIdRef.current

      void applyHighlightWithUndo({
        target: {
          applyVisual: () =>
            highlightRange(rendition, cfiRange, {}, () => {}, 'epubjs-hl', {
              fill: hex,
              'fill-opacity': '0.3',
              'mix-blend-mode': 'multiply'
            }),
          removeVisual: () => removeHighlight(rendition, cfiRange)
        },
        bookSyncId,
        cfiRange,
        text,
        color
      }).then((handle) => {
        setLastUndoable(handle)
        toast('Highlighted', {
          action: { label: 'Undo', onClick: () => void handle.undo() },
          duration: 5_000
        })
      })

      setSelectionInfo(null)
      useSelectionStore.getState().clear()
    },
    [selectionInfo, rendition, setLastUndoable]
  )
```

Notes:
- The duration `5_000` is intentionally the same numeric value as `UNDO_WINDOW_MS` in the hook. Don't import the constant here — the hook owns the keyboard window, and the toast owns the UI duration; they happen to match. If you want a shared source of truth later, it can be refactored.
- The dependency `bookSyncIdRef` is removed from the deps array (refs are stable and don't belong in deps); ESLint may flag this — if so, add `// eslint-disable-next-line react-hooks/exhaustive-deps` on the closing `)` line only if necessary.

- [ ] **Step 4: Run unit + integration tests**

Run: `pnpm test`
Expected: all suites PASS, including the highlight-actions, shortcut hook, and TTSControls suites added earlier.

- [ ] **Step 5: Typecheck and lint**

Run: `pnpm typecheck:web && pnpm lint`
Expected: no errors. If lint complains about the unused `getSyncService` import, remove that import — it is no longer used by `handleHighlightColor`, but check carefully whether other call sites in the file still need it (lines 671 and 804 do — leave the import in).

- [ ] **Step 6: Commit**

```bash
git add src/renderer/src/components/epub/EpubView.tsx
git commit -m "feat(epub): undoable highlights — toast Undo + Cmd/Ctrl+Z"
```

---

## Task 10: Smoke-check the wiring end-to-end (manual)

**Files:** none — exploratory dev session.

- [ ] **Step 1: Start the dev app**

Run: `pnpm dev`
Wait until the Electron window opens.

- [ ] **Step 2: Verify the TTS pill fix**

1. Open any EPUB book in the library.
2. Click the TTS orb at bottom-right to expand the pill.
3. Click Play. Watch the pill while it loads — it must not collapse back to an orb during the loading/playing transition. Let it play for at least 30 seconds, including a page turn (which triggers `pageNavigating` + `republishingParagraphs`). The pill must remain expanded.
4. Pause playback. Within ~4 s the pill should auto-collapse to the orb. (Regression guard — paused must still collapse.)

- [ ] **Step 3: Verify the highlight undo paths**

1. Select a sentence in the EPUB. The color picker popover appears.
2. Click yellow. A sonner toast appears with "Undo".
3. Click "Undo" — the highlight visually disappears and the row is gone (verify via the Highlights panel: open it from the menu; the entry should be absent).
4. Apply another highlight. This time do **not** click the toast; instead press `Cmd+Z` (mac) or `Ctrl+Z` (win/linux). The highlight must be removed.
5. Apply another highlight. Wait ~6 seconds for the toast to vanish. Then press `Cmd+Z` — nothing should happen (window expired).
6. Apply another highlight, then press `Cmd+Shift+Z` — nothing should happen (redo binding is not implemented).

- [ ] **Step 4: If anything in step 2 or 3 fails**

Stop and add a focused test before continuing. Do not commit the fix until the failure is captured by an automated test in the relevant suite.

- [ ] **Step 5: When all manual checks pass, mark this task done**

No commit — this task is verification only.

---

## Task 11: Final lint + typecheck + full test run

**Files:** none — verification gate.

- [ ] **Step 1: Full test suite**

Run: `pnpm test`
Expected: all suites PASS, no flakes.

- [ ] **Step 2: Lint**

Run: `pnpm lint`
Expected: no errors.

- [ ] **Step 3: Typecheck**

Run: `pnpm typecheck`
Expected: no errors.

- [ ] **Step 4: If everything is clean, finish**

No commit — earlier commits covered the changes. The branch is ready for review.

---

## Out of Scope (do NOT touch in this plan)

- `Azw3View.tsx`, `MobiView.tsx`, PDF components — they do not have a `SelectionPopover` flow today; the helper is shaped so they get undo for free when they adopt user highlights.
- Redo (`Cmd+Shift+Z`) — handle is single-use.
- Sharing `UNDO_WINDOW_MS` between hook and toast call site — see note in Task 9 step 3.
