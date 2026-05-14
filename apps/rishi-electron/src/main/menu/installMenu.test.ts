import { describe, it, expect, vi } from 'vitest'
import { MenuInstaller, hashContext } from './installMenu'
import type { MenuContext } from './commands'

const libraryCtx: MenuContext = {
  kind: 'library',
  theme: 'light',
  recentBooks: [],
  openBookTitles: []
}

describe('MenuInstaller', () => {
  it('builds the menu on first install', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    expect(setMenu).toHaveBeenCalledTimes(1)
  })

  it('skips rebuild when context hash unchanged', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    inst.setContext({ ...libraryCtx })
    expect(setMenu).toHaveBeenCalledTimes(1)
  })

  it('rebuilds when identity kind changes', () => {
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, vi.fn())
    inst.setContext(libraryCtx)
    inst.setContext({
      kind: 'book',
      bookId: 1,
      format: 'pdf',
      title: 'X',
      tocOpen: false,
      thumbsOpen: false,
      dualPage: false,
      isReading: false,
      theme: 'light',
      recentBooks: [],
      openBookTitles: [],
      bookmarks: []
    })
    expect(setMenu).toHaveBeenCalledTimes(2)
  })

  it('forwards menu click as { command, arg } via send', () => {
    const send = vi.fn()
    const setMenu = vi.fn()
    const inst = new MenuInstaller(setMenu, send)
    inst.setContext(libraryCtx)
    // pull template, find Import Book, click it
    const tpl = inst.currentTemplate()
    expect(tpl).toBeDefined()
    const file = tpl!.find((m) => m.label === 'File')!
    const sub = file.submenu as Array<{ label?: string; click?: () => void }>
    const importItem = sub.find((m) => m.label === 'Import Book…')!
    importItem.click!()
    expect(send).toHaveBeenCalledWith({ command: 'importBook' })
  })

  it('hashContext changes when tocOpen flips', () => {
    const a: MenuContext = {
      kind: 'book',
      bookId: 1,
      format: 'pdf',
      title: 'X',
      tocOpen: false,
      thumbsOpen: false,
      dualPage: false,
      isReading: false,
      theme: 'light',
      recentBooks: [],
      openBookTitles: [],
      bookmarks: []
    }
    const b = { ...a, tocOpen: true }
    expect(hashContext(a)).not.toBe(hashContext(b))
  })
})
