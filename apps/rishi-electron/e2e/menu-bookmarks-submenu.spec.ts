import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  openBook,
  PDF_FIXTURE,
  clickMenuItem,
  getApplicationMenu,
  findMenuItem
} from './helpers/electron-app'

test('Bookmarks > recent submenu reflects added bookmarks', async () => {
  const launched = await launchApp()
  try {
    const a = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'BM'
    })

    // The test importer doesn't run the cloud sync engine, so sync_id stays
    // null. addBookmark short-circuits without one, so set it directly: the
    // saveBook IPC accepts a sync_id field on upsert.
    await launched.page.evaluate(async (id) => {
      const e = (
        window as unknown as {
          electron: {
            getBook(id: number): Promise<Record<string, unknown> | null>
            saveBook(b: Record<string, unknown>): Promise<unknown>
          }
        }
      ).electron
      const row = await e.getBook(id)
      if (!row) return
      await e.saveBook({ ...row, syncId: `test-sync-${id}` })
    }, a.id)

    const bookPage = await openBook(launched.page, a.id)
    await bookPage.waitForTimeout(2500)

    // Focus the book window so the menu rebuilds to the book context (which
    // is the only one with a Bookmarks top-level menu).
    await launched.app.evaluate(({ BrowserWindow }, bookId) => {
      const winId = `/books/${bookId}`
      const win = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes(winId))
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    }, a.id)
    await bookPage.waitForTimeout(600)

    // Sanity check: Bookmarks top-level should now be in the menu.
    const before = await getApplicationMenu(launched.app)
    expect(findMenuItem(before, ['Bookmarks'])).toBeDefined()

    const clicked = await clickMenuItem(launched.app, ['Bookmarks', 'Add Bookmark'])
    expect(clicked).toBe(true)
    // Allow the add-bookmark IPC roundtrip + the menu publish to complete.
    await bookPage.waitForTimeout(1500)

    const menu = await getApplicationMenu(launched.app)
    const bookmarks = findMenuItem(menu, ['Bookmarks'])
    const labels = (bookmarks?.submenu ?? []).map((m) => m.label).filter((l): l is string => !!l)
    // At least one real bookmark entry beyond the static items + placeholder.
    expect(
      labels.some((l) => l !== 'Add Bookmark' && l !== 'Show All Bookmarks…' && !l.startsWith('('))
    ).toBe(true)
  } finally {
    await closeApp(launched)
  }
})
