import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  openBook,
  EPUB_FIXTURE,
  getApplicationMenu,
  findMenuItem
} from './helpers/electron-app'

test('focused EPUB book window menu hides PDF-only items', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'EPUB M'
    })
    const bookPage = await openBook(launched.page, book.id)
    await bookPage.waitForTimeout(1500)

    await bookPage.bringToFront()
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
    expect(findMenuItem(menu, ['View', 'Show TOC'])).toBeDefined()
    expect(findMenuItem(menu, ['View', 'Show Thumbnails'])).toBeUndefined()
    expect(findMenuItem(menu, ['View', 'Dual Page'])).toBeUndefined()
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['Bookmarks', 'Reader']))
  } finally {
    await closeApp(launched)
  }
})
