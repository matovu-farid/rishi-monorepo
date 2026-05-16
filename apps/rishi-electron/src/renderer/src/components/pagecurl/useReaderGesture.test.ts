import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { act } from '@testing-library/react'
import { useReaderGesture } from './useReaderGesture'

describe('useReaderGesture', () => {
  const defaultCallbacks = {
    onNavigate: vi.fn(() => true),
    onCommit: vi.fn(),
    onUndoNavigate: vi.fn()
  }

  it('starts idle with zero progress', () => {
    const { result } = renderHook(() => useReaderGesture(defaultCallbacks))
    expect(result.current.progress).toBe(0)
    expect(result.current.active).toBe(false)
    expect(result.current.direction).toBe('right')
  })

  it('exposes pointer, wheel, and autoTurn surfaces', () => {
    const { result } = renderHook(() => useReaderGesture(defaultCallbacks))
    const { pointerHandlers, wheelHandlers, autoTurn } = result.current
    expect(typeof pointerHandlers.onPointerDown).toBe('function')
    expect(typeof pointerHandlers.onPointerMove).toBe('function')
    expect(typeof pointerHandlers.onPointerUp).toBe('function')
    expect(typeof pointerHandlers.onPointerCancel).toBe('function')
    expect(typeof wheelHandlers.onWheel).toBe('function')
    expect(typeof autoTurn).toBe('function')
  })
})

function makeMockPointerEvent(opts: {
  clientX: number
  pointerId?: number
  pointerType?: 'mouse' | 'touch' | 'pen'
  width?: number
}): React.PointerEvent {
  const { clientX, pointerId = 1, pointerType = 'mouse', width = 800 } = opts
  return {
    clientX,
    pointerId,
    pointerType,
    currentTarget: {
      getBoundingClientRect: () => ({ left: 0, width, height: 600, top: 0 }),
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn()
    }
  } as unknown as React.PointerEvent
}

describe('useReaderGesture - mouse edge-zone', () => {
  it('claims pointer down within 24 px of left edge (mouse)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 10 }))
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
    expect(result.current.active).toBe(true)
  })

  it('claims pointer down within 24 px of right edge (mouse)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 790 /* width 800, edge 24 → > 776 */ })
      )
    })
    expect(onNavigate).toHaveBeenCalledWith('right')
    expect(result.current.active).toBe(true)
  })

  it('does NOT claim pointer down outside the 24 px edge zone', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 60 }))
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 400 }))
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 770 }))
    })
    expect(onNavigate).not.toHaveBeenCalled()
    expect(result.current.active).toBe(false)
  })
})

describe('useReaderGesture - touch', () => {
  it('ignores single-finger touch even in edge zone', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 10, pointerType: 'touch', pointerId: 1 })
      )
    })
    expect(onNavigate).not.toHaveBeenCalled()
    expect(result.current.active).toBe(false)
  })
})

describe('useReaderGesture - touch two-finger', () => {
  it('claims when a second finger lands (horizontal swipe)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // First finger
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 200, pointerType: 'touch', pointerId: 1 })
      )
      // Second finger — claim should happen now
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
    })
    // Direction inferred from average x: both on left half → assume forward swipe
    // intent is direction-agnostic here; the move handler resolves it. We only
    // assert that the claim happened.
    expect(onNavigate).toHaveBeenCalledTimes(1)
    expect(result.current.active).toBe(true)
  })

  it('releases when one finger lifts so the other becomes single-finger', () => {
    const onCommit = vi.fn()
    const onUndoNavigate = vi.fn()
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate: vi.fn(() => true), onCommit, onUndoNavigate })
    )
    act(() => {
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 200, pointerType: 'touch', pointerId: 1 })
      )
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
      // Lift one finger
      result.current.pointerHandlers.onPointerUp(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
    })
    // Releasing back to 1 finger commits-or-cancels (cancel since progress=0)
    expect(onUndoNavigate).toHaveBeenCalledTimes(1)
  })

  it('does not claim spuriously when a stale touch pointer is left in the map', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // Gesture 1: two fingers, lift one
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 200, pointerType: 'touch', pointerId: 1 })
      )
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
      result.current.pointerHandlers.onPointerUp(
        makeMockPointerEvent({ clientX: 250, pointerType: 'touch', pointerId: 2 })
      )
      // Finger 1 still held. State is now idle (animation completed synchronously
      // via animateTo short-circuit since progress was 0).
      // New finger arrives — should NOT trigger a second claim.
      result.current.pointerHandlers.onPointerDown(
        makeMockPointerEvent({ clientX: 300, pointerType: 'touch', pointerId: 3 })
      )
    })
    // onNavigate called exactly once (the first claim only)
    expect(onNavigate).toHaveBeenCalledTimes(1)
  })
})

function makeWheelEvent(opts: { deltaX: number; deltaY: number }): React.WheelEvent {
  return {
    deltaX: opts.deltaX,
    deltaY: opts.deltaY,
    preventDefault: vi.fn()
  } as unknown as React.WheelEvent
}

describe('useReaderGesture - wheel (trackpad)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('fires onNavigate("right") after accumulating > 50 px of leftward wheel', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // 3 wheel ticks, each deltaX = +20, deltaY = +3 → cumulative 60
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 20, deltaY: 3 }))
    })
    // Debounce hasn't fired yet
    expect(onNavigate).not.toHaveBeenCalled()
    act(() => {
      vi.advanceTimersByTime(130)
    })
    // Positive deltaX = scroll right = next page
    expect(onNavigate).toHaveBeenCalledWith('right')
  })

  it('fires onNavigate("left") for negative deltaX', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: -30, deltaY: 2 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: -30, deltaY: 2 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
  })

  it('does NOT fire when vertical scroll dominates', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // deltaY > deltaX * 1.5 → ignored
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 10, deltaY: 50 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).not.toHaveBeenCalled()
  })

  it('ignores small horizontal deltas (< 6 per tick)', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      for (let i = 0; i < 20; i++) {
        result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 3, deltaY: 0 }))
      }
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).not.toHaveBeenCalled()
  })

  it('does not double-fire within the same debounce window', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 60, deltaY: 5 }))
    })
    act(() => {
      vi.advanceTimersByTime(130)
    })
    expect(onNavigate).toHaveBeenCalledTimes(1)
    act(() => {
      vi.advanceTimersByTime(500)
    })
    expect(onNavigate).toHaveBeenCalledTimes(1)
  })

  it('does not fire wheel-nav when a pointer drag is in progress', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      // Start a mouse drag in the edge zone — claims a curl, state becomes 'dragging'
      result.current.pointerHandlers.onPointerDown(makeMockPointerEvent({ clientX: 10 }))
      // While the drag is in progress, dispatch enough wheel ticks to fire
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 60, deltaY: 5 }))
    })
    expect(onNavigate).toHaveBeenCalledTimes(1) // only the pointer claim
    act(() => {
      vi.advanceTimersByTime(130)
    })
    // The wheel debounce should NOT have fired a second navigation
    expect(onNavigate).toHaveBeenCalledTimes(1)
  })

  it('fires a second time after the buffer resets', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 60, deltaY: 5 }))
    })
    // Advance past debounce (120 ms) + animation (200 ms) so state returns to idle
    act(() => { vi.advanceTimersByTime(350) })
    expect(onNavigate).toHaveBeenCalledTimes(1)

    // Second gesture after the buffer has been cleared and state is back to idle
    act(() => {
      result.current.wheelHandlers.onWheel(makeWheelEvent({ deltaX: 60, deltaY: 5 }))
    })
    act(() => { vi.advanceTimersByTime(350) })
    expect(onNavigate).toHaveBeenCalledTimes(2)
  })
})

describe('useReaderGesture - autoTurn', () => {
  it('calls onNavigate("right") and activates', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.autoTurn('right')
    })
    expect(onNavigate).toHaveBeenCalledWith('right')
    expect(result.current.active).toBe(true)
  })

  it('autoTurn does nothing when onNavigate returns false', () => {
    const onNavigate = vi.fn(() => false)
    const { result } = renderHook(() =>
      useReaderGesture({ onNavigate, onCommit: vi.fn(), onUndoNavigate: vi.fn() })
    )
    act(() => {
      result.current.autoTurn('left')
    })
    expect(onNavigate).toHaveBeenCalledWith('left')
    expect(result.current.active).toBe(false)
  })
})
