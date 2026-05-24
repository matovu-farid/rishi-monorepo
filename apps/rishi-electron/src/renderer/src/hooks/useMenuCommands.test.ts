import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useMenuCommands } from './useMenuCommands'

type Listener = (c: { command: string; arg?: unknown }) => void
let listener: Listener | null = null

// Restore window.electron to whatever test-setup.ts installed at file load so
// per-test stubs in this file cannot leak into other tests in the same file
// (or, if Vitest isolation is ever disabled, into other files).
const originalElectron = (globalThis as unknown as { window: { electron: object } }).window.electron

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

afterEach(() => {
  ;(globalThis as unknown as { window: { electron: object } }).window.electron = originalElectron
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

  it('keeps the listener installed when a handler throws synchronously', () => {
    const importBook = vi.fn(() => {
      throw new Error('boom')
    })
    const toggleTheme = vi.fn()
    renderHook(() => useMenuCommands({ importBook, toggleTheme }))
    expect(() => listener!({ command: 'importBook' })).toThrow('boom')
    // After a throw the bridge must still route subsequent commands.
    expect(listener).not.toBeNull()
    listener!({ command: 'toggleTheme' })
    expect(toggleTheme).toHaveBeenCalledTimes(1)
  })

  it('routes commands to distinct handlers in dispatch order', () => {
    const calls: string[] = []
    const handlers = {
      importBook: vi.fn(() => calls.push('importBook')),
      toggleTheme: vi.fn(() => calls.push('toggleTheme')),
      openSearch: vi.fn(() => calls.push('openSearch'))
    }
    renderHook(() => useMenuCommands(handlers))
    listener!({ command: 'toggleTheme' })
    listener!({ command: 'importBook' })
    listener!({ command: 'openSearch' })
    listener!({ command: 'importBook' })

    expect(handlers.toggleTheme).toHaveBeenCalledTimes(1)
    expect(handlers.openSearch).toHaveBeenCalledTimes(1)
    expect(handlers.importBook).toHaveBeenCalledTimes(2)
    expect(calls).toEqual(['toggleTheme', 'importBook', 'openSearch', 'importBook'])
  })
})
