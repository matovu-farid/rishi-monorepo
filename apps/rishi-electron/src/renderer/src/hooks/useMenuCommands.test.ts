import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useMenuCommands } from './useMenuCommands'

type Listener = (c: { command: string; arg?: unknown }) => void
let listener: Listener | null = null

beforeEach(() => {
  listener = null
  ;(globalThis as unknown as { window: { electron: object } }).window.electron = {
    onMenuCommand: (cb: Listener) => {
      listener = cb
      return () => {
        listener = null
      }
    },
    windowIdentity: { kind: 'library' }
  } as object
})

describe('useMenuCommands', () => {
  it('dispatches importBook to handler', () => {
    const handlers = { importBook: vi.fn(), toggleTheme: vi.fn() }
    renderHook(() => useMenuCommands(handlers))
    listener!({ command: 'importBook' })
    expect(handlers.importBook).toHaveBeenCalled()
  })

  it('ignores commands with no registered handler', () => {
    const handlers = { importBook: vi.fn() }
    renderHook(() => useMenuCommands(handlers))
    expect(() => listener!({ command: 'doesNotExist' })).not.toThrow()
  })

  it('unsubscribes on unmount', () => {
    const dispose = vi.fn()
    ;(globalThis as unknown as { window: { electron: object } }).window.electron = {
      onMenuCommand: () => dispose,
      windowIdentity: { kind: 'library' }
    } as object
    const { unmount } = renderHook(() => useMenuCommands({}))
    unmount()
    expect(dispose).toHaveBeenCalled()
  })
})
