import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  openBook,
  clickMenuItem,
  PDF_FIXTURE
} from './helpers/electron-app'

test('View > Switch to Dark Mode toggles theme in renderer', async () => {
  const launched = await launchApp()
  try {
    // The native menu only rebuilds for the focused window; ensure we have
    // focus so `clickMenuItem` dispatches to the right webContents (parallel
    // workers can race for focus otherwise).
    await launched.app.evaluate(({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows()[0]
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    })
    await launched.page.waitForTimeout(200)
    const themeBefore = await launched.page.evaluate(() =>
      document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    )
    const label = themeBefore === 'dark' ? 'Switch to Light Mode' : 'Switch to Dark Mode'
    const clicked = await clickMenuItem(launched.app, ['View', label])
    expect(clicked).toBe(true)
    await launched.page.waitForTimeout(300)
    const themeAfter = await launched.page.evaluate(() =>
      document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    )
    expect(themeAfter).not.toBe(themeBefore)
  } finally {
    await closeApp(launched)
  }
})

test('Bookmarks > Add Bookmark adds a row in the DB when a PDF is open', async () => {
  test.setTimeout(120000)
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Menu PDF'
    })

    // syncId is normally assigned by background sync. Seed one synchronously
    // before opening the book so the addBookmark menu handler (which keys
    // off bookSyncId) picks up a non-null target on first mount.
    const syncId = await launched.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const existing = (await e.booksGetSyncId(id)) as string | null
      if (existing) return existing
      const row = (await e.getBook(id)) as Record<string, unknown> | null
      if (!row) return null
      const newId = crypto.randomUUID()
      await e.saveBook({ ...row, id, syncId: newId })
      return newId
    }, book.id)
    if (!syncId) {
      test.skip(true, 'bookSyncId could not be assigned for the imported PDF')
      return
    }

    await openBook(launched.page, book.id)
    // Wait for the PDF reader to mount and resolve its bookSyncId so
    // `addBookmark` has a target. The toolbar's Next-page button is the same
    // anchor `bookmarks.spec.ts` waits on.
    await launched.page
      .locator('[aria-label="Next page"]')
      .first()
      .waitFor({ timeout: 30000 })
      .catch(() => {})
    await launched.page.waitForTimeout(1200)

    // The renderer doesn't yet auto-publish menu context on route change
    // (that wiring lands in Phase 4). Force-focus the window then push the
    // book context via the real `setMenuContext` IPC so the native menu
    // exposes Bookmarks > Add Bookmark for this test.
    await launched.app.evaluate(({ BrowserWindow }) => {
      const wins = BrowserWindow.getAllWindows()
      const win = wins[0]
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    })
    await launched.page.waitForTimeout(200)
    await launched.page.evaluate(
      ({ id, title }) => {
        const e = (
          window as unknown as {
            electron: { setMenuContext: (p: Record<string, unknown>) => void }
          }
        ).electron
        e.setMenuContext({
          kind: 'book',
          bookId: id,
          format: 'pdf',
          title,
          tocOpen: false,
          thumbsOpen: false,
          dualPage: false,
          isReading: false,
          theme: 'light',
          recentBooks: [],
          openBookTitles: [{ bookId: id, title }],
          bookmarks: []
        })
      },
      { id: book.id, title: book.title }
    )
    await launched.page.waitForTimeout(400)

    const before = await launched.page.evaluate(async (sid) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const list = (await e.bookmarksList(sid)) as unknown[]
      return list.length
    }, syncId)

    const clicked = await clickMenuItem(launched.app, ['Bookmarks', 'Add Bookmark'])
    expect(clicked).toBe(true)
    await launched.page.waitForTimeout(800)

    const after = await launched.page.evaluate(async (sid) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const list = (await e.bookmarksList(sid)) as unknown[]
      return list.length
    }, syncId)
    expect(after).toBe(before + 1)
  } finally {
    await closeApp(launched)
  }
})
