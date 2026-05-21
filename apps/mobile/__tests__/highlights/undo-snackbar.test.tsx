/**
 * G10 — Undo snackbar after highlight delete.
 *
 * The snackbar is a small in-house component that mounts on top of the
 * reader, accepts a `{ visible, message, actionLabel, onAction, onDismiss }`
 * prop bag, and auto-dismisses after the supplied duration.
 *
 * We test the underlying `useUndoSnackbar` hook — show / dismiss / undo
 * dispatch logic — using react-test-renderer with native primitives
 * mocked. The hook is store-shaped (single in-memory slot with a
 * timer), matching electron's `useUndoableHighlightShortcut.ts`.
 */
jest.mock('react-native-mmkv', () => ({
  createMMKV: jest.fn(() => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  })),
}))

jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((p: any, r: unknown) => React.createElement('View', { ...p, ref: r })),
    Text: React.forwardRef((p: any, r: unknown) => React.createElement('Text', { ...p, ref: r })),
    Pressable: React.forwardRef((p: any, r: unknown) =>
      React.createElement('Pressable', { ...p, ref: r }),
    ),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

import { useUndoSnackbar, UNDO_SNACKBAR_DURATION_MS } from '@/hooks/useUndoSnackbar'
import React from 'react'
import TestRenderer, { act } from 'react-test-renderer'

function Harness({ onState }: { onState: (state: ReturnType<typeof useUndoSnackbar>) => void }) {
  const state = useUndoSnackbar()
  React.useEffect(() => {
    onState(state)
  })
  return null
}

describe('useUndoSnackbar', () => {
  beforeEach(() => {
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('starts hidden', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    expect(s.visible).toBe(false)
    expect(s.message).toBeNull()
  })

  it('show() makes the snackbar visible with the supplied message + action', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    const undo = jest.fn()
    act(() => {
      s.show('Highlight deleted', 'Undo', undo)
    })
    expect(s.visible).toBe(true)
    expect(s.message).toBe('Highlight deleted')
    expect(s.actionLabel).toBe('Undo')
  })

  it('auto-dismisses after the default duration', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    act(() => {
      s.show('msg', 'Undo', jest.fn())
    })
    expect(s.visible).toBe(true)
    act(() => {
      jest.advanceTimersByTime(UNDO_SNACKBAR_DURATION_MS + 50)
    })
    expect(s.visible).toBe(false)
  })

  it('action() invokes onAction and hides immediately', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    const undo = jest.fn()
    act(() => {
      s.show('deleted', 'Undo', undo)
    })
    act(() => {
      s.action()
    })
    expect(undo).toHaveBeenCalledTimes(1)
    expect(s.visible).toBe(false)
  })

  it('action() is a no-op after the snackbar auto-dismisses', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    const undo = jest.fn()
    act(() => {
      s.show('deleted', 'Undo', undo)
    })
    act(() => {
      jest.advanceTimersByTime(UNDO_SNACKBAR_DURATION_MS + 50)
    })
    act(() => {
      s.action()
    })
    expect(undo).not.toHaveBeenCalled()
  })

  // H2-02: timer cleanup on unmount. A `show()` call schedules a 5s
  // setTimeout that calls setState. If the consumer unmounts before the
  // timer fires (e.g. the user navigates away), the timer fires against
  // a stale component and React logs a "Can't perform a React state
  // update on an unmounted component" warning. The hook MUST clear its
  // timer on cleanup.
  it('does not fire its auto-dismiss timer after the host unmounts (H2-02)', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    act(() => {
      s.show('msg', 'Undo', jest.fn())
    })
    // Spy on setTimeout/clearTimeout call counts before unmount.
    const pendingTimersBefore = jest.getTimerCount()
    expect(pendingTimersBefore).toBeGreaterThan(0)

    act(() => {
      tree.unmount()
    })

    // After unmount, the auto-dismiss timer should have been cleared.
    // Without the fix `jest.getTimerCount()` stays > 0 because the
    // 5s setTimeout still has a pending handle.
    expect(jest.getTimerCount()).toBe(0)
  })

  it('a second show() replaces the previous action and resets the timer', () => {
    let s!: ReturnType<typeof useUndoSnackbar>
    act(() => {
      TestRenderer.create(<Harness onState={(state) => (s = state)} />)
    })
    const undoA = jest.fn()
    const undoB = jest.fn()
    act(() => {
      s.show('A', 'Undo', undoA)
    })
    act(() => {
      jest.advanceTimersByTime(UNDO_SNACKBAR_DURATION_MS / 2)
    })
    act(() => {
      s.show('B', 'Undo', undoB)
    })
    expect(s.message).toBe('B')

    // Tap the action — only the latest handler should fire.
    act(() => {
      s.action()
    })
    expect(undoA).not.toHaveBeenCalled()
    expect(undoB).toHaveBeenCalledTimes(1)
  })
})
