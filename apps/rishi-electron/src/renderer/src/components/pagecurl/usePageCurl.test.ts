import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePageCurl } from './usePageCurl'

describe('usePageCurl', () => {
  const defaultCallbacks = {
    onNavigate: vi.fn(() => true),
    onCommit: vi.fn(),
    onUndoNavigate: vi.fn()
  }

  it('starts idle with zero progress', () => {
    const { result } = renderHook(() => usePageCurl(defaultCallbacks))
    expect(result.current.progress).toBe(0)
    expect(result.current.active).toBe(false)
    expect(result.current.direction).toBe('right')
  })

  it('exposes pointer handler functions', () => {
    const { result } = renderHook(() => usePageCurl(defaultCallbacks))
    const { pointerHandlers } = result.current
    expect(typeof pointerHandlers.onPointerDown).toBe('function')
    expect(typeof pointerHandlers.onPointerMove).toBe('function')
    expect(typeof pointerHandlers.onPointerUp).toBe('function')
    expect(typeof pointerHandlers.onPointerCancel).toBe('function')
  })

  it('exposes an autoTurn function', () => {
    const { result } = renderHook(() => usePageCurl(defaultCallbacks))
    expect(typeof result.current.autoTurn).toBe('function')
  })

  it('autoTurn calls onNavigate', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() => usePageCurl({ ...defaultCallbacks, onNavigate }))

    act(() => {
      result.current.autoTurn('right')
    })

    expect(onNavigate).toHaveBeenCalledWith('right')
    expect(result.current.active).toBe(true)
  })

  it('autoTurn does nothing when onNavigate returns false', () => {
    const onNavigate = vi.fn(() => false)
    const { result } = renderHook(() => usePageCurl({ ...defaultCallbacks, onNavigate }))

    act(() => {
      result.current.autoTurn('left')
    })

    expect(onNavigate).toHaveBeenCalledWith('left')
    expect(result.current.active).toBe(false)
  })

  it('ignores pointerDown outside edge zones', () => {
    const onNavigate = vi.fn(() => true)
    const { result } = renderHook(() => usePageCurl({ ...defaultCallbacks, onNavigate }))

    const mockEvent = {
      clientX: 400,
      currentTarget: {
        getBoundingClientRect: () => ({ left: 0, width: 800 }),
        setPointerCapture: vi.fn()
      },
      pointerId: 1
    } as unknown as React.PointerEvent

    act(() => {
      result.current.pointerHandlers.onPointerDown(mockEvent)
    })

    // 400 is in the middle -- not near left (< 60) or right (> 740)
    expect(onNavigate).not.toHaveBeenCalled()
    expect(result.current.active).toBe(false)
  })
})
