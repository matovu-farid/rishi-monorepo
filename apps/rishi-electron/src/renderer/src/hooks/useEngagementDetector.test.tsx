import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const sendMock = vi.fn()
vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

import { useEngagementDetector } from './useEngagementDetector'

describe('useEngagementDetector', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    sendMock.mockClear()
  })
  afterEach(() => vi.useRealTimers())

  it('fires ENGAGEMENT_TAP on pointerdown', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    act(() => {
      targetRef.current.dispatchEvent(new PointerEvent('pointerdown'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'ENGAGEMENT_TAP' })
  })

  it('fires ENGAGEMENT_TAP on selectionchange when a non-collapsed range exists', () => {
    const targetRef = { current: document.createElement('div') }
    targetRef.current.textContent = 'hello world'
    document.body.appendChild(targetRef.current)
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    const range = document.createRange()
    range.selectNodeContents(targetRef.current)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)
    act(() => {
      document.dispatchEvent(new Event('selectionchange'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'ENGAGEMENT_TAP' })
    document.body.removeChild(targetRef.current)
  })

  it('does NOT fire on selectionchange when selection is collapsed', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    window.getSelection()?.removeAllRanges()
    act(() => {
      document.dispatchEvent(new Event('selectionchange'))
    })
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('does NOT fire when enabled is false', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: false }))
    act(() => {
      targetRef.current.dispatchEvent(new PointerEvent('pointerdown'))
    })
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('fires VISIBILITY_HIDDEN on visibilitychange when document hidden', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    act(() => {
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'VISIBILITY_HIDDEN' })
  })

  it('fires VISIBILITY_VISIBLE on visibilitychange when document visible', () => {
    const targetRef = { current: document.createElement('div') }
    renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true })
    act(() => {
      document.dispatchEvent(new Event('visibilitychange'))
    })
    expect(sendMock).toHaveBeenCalledWith({ type: 'VISIBILITY_VISIBLE' })
  })

  it('removes listeners on unmount', () => {
    const targetRef = { current: document.createElement('div') }
    const { unmount } = renderHook(() => useEngagementDetector({ targetRef, enabled: true }))
    unmount()
    sendMock.mockClear()
    act(() => {
      targetRef.current.dispatchEvent(new PointerEvent('pointerdown'))
    })
    expect(sendMock).not.toHaveBeenCalled()
  })
})
