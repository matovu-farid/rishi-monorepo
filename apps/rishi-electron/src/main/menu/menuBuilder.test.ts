import { describe, it, expect, vi } from 'vitest'
import type { MenuCommand, MenuContext } from './commands'
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
})
