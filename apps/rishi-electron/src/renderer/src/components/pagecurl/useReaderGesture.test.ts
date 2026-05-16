import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
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
