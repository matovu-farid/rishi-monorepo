import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useUndoableHighlightShortcut, UNDO_WINDOW_MS } from './useUndoableHighlightShortcut'

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

  it('ignores Cmd+Shift+Z (reserved for future redo binding)', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()
    act(() => {
      result.current.setLastUndoable(handle)
    })
    act(() => {
      window.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'z', metaKey: true, shiftKey: true })
      )
    })
    expect(handle.undo).not.toHaveBeenCalled()
  })

  it('ignores Cmd+Z when focus is in a contentEditable element', () => {
    const { result } = renderHook(() => useUndoableHighlightShortcut())
    const handle = makeHandle()

    const editable = document.createElement('div')
    editable.contentEditable = 'true'
    document.body.appendChild(editable)
    editable.focus()

    act(() => {
      result.current.setLastUndoable(handle)
    })
    act(() => {
      editable.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true })
      )
    })

    expect(handle.undo).not.toHaveBeenCalled()
    document.body.removeChild(editable)
  })
})
