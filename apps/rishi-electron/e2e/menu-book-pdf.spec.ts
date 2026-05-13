import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  openBook,
  PDF_FIXTURE,
  getApplicationMenu,
  findMenuItem
} from './helpers/electron-app'

test('focused PDF book window menu has Bookmarks, Reader, Show Thumbnails, Dual Page', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'PDF M'
    })
    const bookPage = await openBook(launched.page, book.id)
    await bookPage.waitForTimeout(1500)

    await bookPage.bringToFront()
    // Also force-focus the matching BrowserWindow in main so the menu rebuilds.
    await launched.app.evaluate(
      ({ BrowserWindow }, { url }) => {
        const wins = BrowserWindow.getAllWindows()
        const win = wins.find((w) => w.webContents.getURL().includes(url)) ?? wins[0]
        if (!win) return
        if (win.isMinimized()) win.restore()
        win.show()
        win.focus()
      },
      { url: `/books/${book.id}` }
    )
    await launched.page.waitForTimeout(800)

    const menu = await getApplicationMenu(launched.app)
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['Bookmarks', 'Reader']))
    expect(findMenuItem(menu, ['View', 'Show Thumbnails'])).toBeDefined()
    expect(findMenuItem(menu, ['View', 'Dual Page'])).toBeDefined()
  } finally {
    await closeApp(launched)
  }
})
