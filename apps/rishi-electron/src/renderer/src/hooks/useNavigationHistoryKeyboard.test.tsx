import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

const sendMock = vi.fn()
vi.mock('@/machines/navigationHistory/navigationHistoryActor', () => ({
  navigationHistoryActor: { send: (e: unknown) => sendMock(e) }
}))

import { useNavigationHistoryKeyboard } from './useNavigationHistoryKeyboard'

describe('useNavigationHistoryKeyboard', () => {
  beforeEach(() => sendMock.mockClear())

  it('Cmd+[ dispatches POP_BACK', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[', metaKey: true }))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('Ctrl+[ dispatches POP_BACK', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[', ctrlKey: true }))
    expect(sendMock).toHaveBeenCalledWith({ type: 'POP_BACK' })
  })

  it('plain [ does NOT dispatch', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[' }))
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('Cmd+] does NOT dispatch (wrong key)', () => {
    renderHook(() => useNavigationHistoryKeyboard())
    window.dispatchEvent(new KeyboardEvent('keydown', { key: ']', metaKey: true }))
    expect(sendMock).not.toHaveBeenCalled()
  })

  it('removes listener on unmount', () => {
    const { unmount } = renderHook(() => useNavigationHistoryKeyboard())
    unmount()
    sendMock.mockClear()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '[', metaKey: true }))
    expect(sendMock).not.toHaveBeenCalled()
  })
})
