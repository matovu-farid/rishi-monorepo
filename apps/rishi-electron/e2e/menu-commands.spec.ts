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
    // `addBookmark` has a target. The toolbar's Next-page button is the same
    // anchor `bookmarks.spec.ts` waits on.
    await bookPage
      .locator('[aria-label="Next page"]')
      .first()
      .waitFor({ timeout: 30000 })
      .catch(() => {})
    await bookPage.waitForTimeout(1200)

    // Focus the book window so the native menu rebuilds against its context
    // (pre-seeded by `window:openBook` from the DB row). Phase 3 spawned the
    // window with the correct identity + context, so we no longer need to
    // hand-push setMenuContext from the test — focus is enough.
    const bookWebContentsId = await bookPage.evaluate(
      // Each Page has its own WebContents; this returns the window in main
      // that owns it. Not directly exposed — we instead bringToFront via the
      // Playwright Page handle.
      () => 0
    )
    void bookWebContentsId
    await bookPage.bringToFront()
    await launched.app.evaluate(({ BrowserWindow }, { url }) => {
      const wins = BrowserWindow.getAllWindows()
      const win = wins.find((w) => w.webContents.getURL().includes(url)) ?? wins[0]
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    }, { url: `/books/${book.id}` })
    await launched.page.waitForTimeout(800)

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
