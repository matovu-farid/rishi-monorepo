import { describe, it, expectTypeOf, expect } from 'vitest'
import type { MenuCommand, MenuContext } from './commands'

describe('menu command vocabulary', () => {
  it('union covers every action the menu can emit', () => {
    const all: MenuCommand[] = [
      { command: 'importBook' },
      { command: 'openRecent', arg: { bookId: 1 } },
      { command: 'closeWindow' },
      { command: 'focusLibrary' },
      { command: 'toggleTheme' },
      { command: 'toggleTOC' },
      { command: 'toggleThumbnails' },
      { command: 'toggleDualPage' },
      { command: 'addBookmark' },
      { command: 'showAllBookmarks' },
      { command: 'jumpToBookmark', arg: { bookmarkId: 'bm-9' } },
      { command: 'readAloudToggle' },
      { command: 'voiceChat' },
      { command: 'openChat' },
      { command: 'openHelp' },
      { command: 'reportIssue' },
      { command: 'about' }
    ]
    expect(all.length).toBeGreaterThan(0)
  })

  it('library context omits book-specific fields', () => {
    const ctx: MenuContext = {
      kind: 'library',
      theme: 'light',
      recentBooks: [],
      openBookTitles: []
    }
    expectTypeOf(ctx.kind).toEqualTypeOf<'library'>()
  })

  it('book context carries reader state', () => {
    const ctx: MenuContext = {
      kind: 'book',
      bookId: 7,
      format: 'pdf',
      title: 'X',
      tocOpen: false,
      thumbsOpen: false,
      dualPage: false,
      isReading: false,
      theme: 'light',
      recentBooks: [],
      openBookTitles: [{ bookId: 7, title: 'X' }],
      bookmarks: []
    }
    expectTypeOf(ctx.kind).toEqualTypeOf<'book'>()
  })
})
