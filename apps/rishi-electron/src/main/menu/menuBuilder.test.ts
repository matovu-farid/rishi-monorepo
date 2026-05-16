import { describe, it, expect, vi } from 'vitest'
import type { MenuItemConstructorOptions } from 'electron'
import type { BookMenuContext, MenuCommand, MenuContext } from './commands'
import { buildMenu, findItem } from './menuBuilder'

const libraryCtx: MenuContext = {
  kind: 'library',
  theme: 'light',
  recentBooks: [],
  openBookTitles: []
}

describe('buildMenu — library', () => {
  it('has top-level File, Edit, View, Window, Help', () => {
    const tpl = buildMenu(libraryCtx, vi.fn())
    const labels = tpl.map((m) => m.label ?? m.role)
    expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View', 'Window', 'Help']))
  })

  it('does NOT include Bookmarks or Reader top-level', () => {
    const tpl = buildMenu(libraryCtx, vi.fn())
    const labels = tpl.map((m) => m.label)
    expect(labels).not.toContain('Bookmarks')
    expect(labels).not.toContain('Reader')
  })

  it('File > Import Book dispatches { command: "importBook" }', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(libraryCtx, dispatch)
    const importItem = findItem(tpl, ['File', 'Import Book…'])
    expect(importItem).toBeDefined()
    expect(importItem!.accelerator).toBe('CmdOrCtrl+O')
    importItem!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'importBook' })
  })

  it('Window > Library dispatches focusLibrary with CmdOrCtrl+1', () => {
    const dispatch = vi.fn()
    const tpl = buildMenu(libraryCtx, dispatch)
    const libItem = findItem(tpl, ['Window', 'Library'])
    expect(libItem!.accelerator).toBe('CmdOrCtrl+1')
    libItem!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'focusLibrary' })
  })

  it('View > Toggle Theme label reflects current theme', () => {
    const dark: MenuContext = { ...libraryCtx, theme: 'dark' }
    const labelLight = findItem(buildMenu(libraryCtx, vi.fn()), ['View', 'Switch to Dark Mode'])
    const labelDark = findItem(buildMenu(dark, vi.fn()), ['View', 'Switch to Light Mode'])
    expect(labelLight).toBeDefined()
    expect(labelDark).toBeDefined()
  })

  it('View exposes Reload, Force Reload, and Toggle Developer Tools', () => {
    const tpl = buildMenu(libraryCtx, vi.fn())
    expect(findItem(tpl, ['View', 'Reload'])?.role).toBe('reload')
    expect(findItem(tpl, ['View', 'Force Reload'])?.role).toBe('forceReload')
    expect(findItem(tpl, ['View', 'Toggle Developer Tools'])?.role).toBe('toggleDevTools')
  })

  it('macOS app menu has Preferences with CmdOrCtrl+, that dispatches openSettings', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(libraryCtx, dispatch)
    // On non-mac, the app menu is not present — skip then.
    const isMac = process.platform === 'darwin'
    if (!isMac) return
    const prefs = findItem(tpl, ['Rishi', 'Preferences…'])
    expect(prefs).toBeDefined()
    expect(prefs!.accelerator).toBe('CmdOrCtrl+,')
    prefs!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'openSettings' })
  })

  it('macOS app menu has Check for Updates that dispatches checkForUpdates', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(libraryCtx, dispatch)
    const isMac = process.platform === 'darwin'
    if (!isMac) return
    const item = findItem(tpl, ['Rishi', 'Check for Updates…'])
    expect(item).toBeDefined()
    item!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'checkForUpdates' })
  })
})

const pdfCtx: BookMenuContext = {
  kind: 'book',
  bookId: 1,
  format: 'pdf',
  title: 'PDF Book',
  tocOpen: false,
  thumbsOpen: false,
  dualPage: false,
  isReading: false,
  theme: 'light',
  recentBooks: [],
  openBookTitles: [{ bookId: 1, title: 'PDF Book' }],
  bookmarks: []
}

describe('buildMenu — book', () => {
  it('PDF context exposes Show Thumbnails and Dual Page under View', () => {
    const tpl = buildMenu(pdfCtx, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeDefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeDefined()
  })

  it('EPUB hides PDF-only items', () => {
    const tpl = buildMenu({ ...pdfCtx, format: 'epub' }, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Show TOC'])).toBeDefined()
  })

  it('MOBI hides PDF-only items', () => {
    const tpl = buildMenu({ ...pdfCtx, format: 'mobi' }, vi.fn())
    expect(findItem(tpl, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findItem(tpl, ['View', 'Dual Page'])).toBeUndefined()
  })

  it('Show TOC reflects tocOpen as checked', () => {
    const open = buildMenu({ ...pdfCtx, tocOpen: true }, vi.fn())
    const closed = buildMenu({ ...pdfCtx, tocOpen: false }, vi.fn())
    expect(findItem(open, ['View', 'Show TOC'])?.checked).toBe(true)
    expect(findItem(closed, ['View', 'Show TOC'])?.checked).toBe(false)
  })

  it('Read Aloud label flips when isReading', () => {
    const idle = buildMenu(pdfCtx, vi.fn())
    const playing = buildMenu({ ...pdfCtx, isReading: true }, vi.fn())
    expect(findItem(idle, ['Reader', 'Read Aloud'])).toBeDefined()
    expect(findItem(playing, ['Reader', 'Stop Read Aloud'])).toBeDefined()
  })

  it('Read Aloud From Selection has CmdOrCtrl+Shift+L and dispatches readAloudFromSelection', () => {
    const dispatch = vi.fn<(c: MenuCommand) => void>()
    const tpl = buildMenu(pdfCtx, dispatch)
    const item = findItem(tpl, ['Reader', 'Read Aloud From Selection'])
    expect(item).toBeDefined()
    expect(item!.accelerator).toBe('CmdOrCtrl+Shift+L')
    item!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'readAloudFromSelection' })
  })

  it('Bookmarks > Add Bookmark dispatches addBookmark', () => {
    const dispatch = vi.fn()
    const tpl = buildMenu(pdfCtx, dispatch)
    const item = findItem(tpl, ['Bookmarks', 'Add Bookmark'])
    item!.click!(undefined as never, undefined as never, undefined as never)
    expect(dispatch).toHaveBeenCalledWith({ command: 'addBookmark' })
  })

  it('Open Recent submenu caps at 10', () => {
    const many = Array.from({ length: 25 }, (_, i) => ({ bookId: i, title: `B${i}` }))
    const tpl = buildMenu({ ...pdfCtx, recentBooks: many }, vi.fn())
    const recent = findItem(tpl, ['File', 'Open Recent'])
    expect((recent!.submenu as MenuItemConstructorOptions[]).length).toBe(10)
  })
})
