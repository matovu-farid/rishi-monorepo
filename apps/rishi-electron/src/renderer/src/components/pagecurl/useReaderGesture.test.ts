import { describe, it, expect, vi } from 'vitest'
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
