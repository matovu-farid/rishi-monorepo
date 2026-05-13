import { describe, it, expect, vi } from 'vitest'
import { WindowManager, type WindowFactory, type ManagedWindow } from './windowManager'

function makeFakeWindow(): ManagedWindow {
  const listeners: Array<() => void> = []
  return {
    focus: vi.fn(),
    close: vi.fn(() => listeners.forEach((l) => l())),
    isDestroyed: vi.fn(() => false),
    on: vi.fn((event: string, cb: () => void) => {
      if (event === 'closed') listeners.push(cb)
    }),
    webContents: { send: vi.fn() }
  } as unknown as ManagedWindow
}

describe('WindowManager', () => {
  it('openLibrary creates a window the first time', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    const w = wm.openLibrary()
    expect(factory).toHaveBeenCalledTimes(1)
    expect(w).toBeDefined()
  })

  it('openLibrary returns the existing window on second call', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    const a = wm.openLibrary()
    const b = wm.openLibrary()
    expect(a).toBe(b)
    expect(factory).toHaveBeenCalledTimes(1)
    expect((a as unknown as { focus: ReturnType<typeof vi.fn> }).focus).toHaveBeenCalled()
  })

  it('openBook creates a new window for unknown bookId', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const w = wm.openBook(7)
    expect(factory).toHaveBeenCalledTimes(2)
    expect(w).toBeDefined()
  })

  it('openBook returns existing window for known bookId', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const a = wm.openBook(7)
    const b = wm.openBook(7)
    expect(a).toBe(b)
    expect(factory).toHaveBeenCalledTimes(2)
  })

  it('closeBook removes the window from the map', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    wm.openBook(7)
    expect(wm.hasBook(7)).toBe(true)
    wm.closeBook(7)
    expect(wm.hasBook(7)).toBe(false)
  })

  it('removes book from map when window emits closed', () => {
    const factory: WindowFactory = vi.fn(() => makeFakeWindow())
    const wm = new WindowManager(factory)
    wm.openLibrary()
    const w = wm.openBook(7) as unknown as ManagedWindow
    expect(wm.hasBook(7)).toBe(true)
    w.close()
    expect(wm.hasBook(7)).toBe(false)
  })
})
