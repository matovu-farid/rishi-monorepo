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

    const bookPage = await openBook(launched.page, book.id)
    // Wait for the PDF reader to mount and resolve its bookSyncId so
    // `addBookmark` has a target.
    await bookPage
      .locator('[aria-label="Next page"]')
      .first()
      .waitFor({ timeout: 30000 })
      .catch(() => {})
    await bookPage.waitForTimeout(1200)

    // Read bookmark count BEFORE clicking — query via the book window to
    // avoid moving focus away. Either window can read the DB; the IPC is
    // process-global.
    const before = await bookPage.evaluate(async (sid) => {
      const e = (window as unknown as { electron: Record<string, Function> }).electron
      const list = (await e.bookmarksList(sid)) as unknown[]
      return list.length
    }, syncId)

    // The menu dispatcher in main sends `menu:command` to the focused
    // window, and only the PDF reader has an `addBookmark` handler.
    // macOS may bounce focus between windows under Playwright; retry a
    // few times until the bookmark count actually moves.
    let after = before
    for (let attempt = 0; attempt < 5 && after === before; attempt++) {
      await launched.app
        .evaluate(
          ({ BrowserWindow }, { url }) => {
            const wins = BrowserWindow.getAllWindows()
            const win = wins.find((w) => w.webContents.getURL().includes(url))
            if (!win) return
            if (win.isMinimized()) win.restore()
            win.show()
            win.focus()
          },
          { url: `/books/${book.id}` }
        )
        .catch(() => {})
      await bookPage.bringToFront()
      await launched.page.waitForTimeout(400)
      const clicked = await clickMenuItem(launched.app, ['Bookmarks', 'Add Bookmark'])
      expect(clicked).toBe(true)
      await launched.page.waitForTimeout(1200)
      after = await bookPage.evaluate(async (sid) => {
        const e = (window as unknown as { electron: Record<string, Function> }).electron
        const list = (await e.bookmarksList(sid)) as unknown[]
        return list.length
      }, syncId)
    }
    expect(after).toBeGreaterThan(before)
  } finally {
    await closeApp(launched)
  }
})
