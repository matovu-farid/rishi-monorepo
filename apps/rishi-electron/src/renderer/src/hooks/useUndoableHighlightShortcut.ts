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

  // Cancel any pending expiry timer when the hook unmounts. Written
  // self-contained (not `() => clearLastUndoable`) so future changes to
  // `clearLastUndoable`'s deps can't accidentally make this run every render.
  useEffect(() => {
    return () => {
      if (slotRef.current) {
        clearTimeout(slotRef.current.timer)
        slotRef.current = null
      }
    }
  }, [])

  return { setLastUndoable, clearLastUndoable }
}
