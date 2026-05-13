import { test, expect } from '@playwright/test'
import {
  AZW3_FIXTURE,
  clickMenuItem,
  closeApp,
  importBook,
  launchApp,
  openBook
} from './helpers/electron-app'

// Feature-parity tests for AZW3 against MOBI's capability set: chapter
// navigation, TOC sheet, and add-bookmark via native menu.
test.describe('AZW3 reader — feature parity with MOBI', () => {
  test('chapter Next/Prev chevrons advance the counter', async () => {
    const launched = await launchApp()
    try {
      const book = await importBook(launched.page, {
        fixturePath: AZW3_FIXTURE,
        kind: 'azw3',
        title: 'AZW3 Nav Test'
      })
      const bookPage = await openBook(launched.page, book.id)

      const counter = bookPage.locator('text=/^\\d+\\s*\\/\\s*\\d+$/').first()
      await counter.waitFor({ state: 'visible', timeout: 20000 })

      // Skip the navigation assertion if the test fixture has only one
      // section (the Next button would be disabled). The test still proves
      // the navigation UI is wired by reading the counter.
      const initial = (await counter.textContent())?.trim() ?? ''
      const [, totalStr] = initial.split('/')
      const total = Number(totalStr.trim())
      if (total < 2) {
        // Single-section fixture — assert that Next is disabled and we're at 1/1.
        expect(initial).toMatch(/^1\s*\/\s*1$/)
        const next = bookPage.locator('button[aria-label="Next chapter"]')
        await expect(next).toBeDisabled()
        return
      }

      // Multi-section fixture — click Next, counter must advance by one.
      const [currentStr] = initial.split('/')
      const current = Number(currentStr.trim())
      await bookPage.locator('button[aria-label="Next chapter"]').click()
      await expect(counter).toHaveText(new RegExp(`^${current + 1}\\s*/\\s*\\d+$`), {
        timeout: 5000
      })

      // Click Prev — counter returns to the original position.
      await bookPage.locator('button[aria-label="Previous chapter"]').click()
      await expect(counter).toHaveText(new RegExp(`^${current}\\s*/\\s*\\d+$`), {
        timeout: 5000
      })
    } finally {
      await closeApp(launched)
    }
  })

  test('View > Show TOC opens the TOC sheet', async () => {
    const launched = await launchApp()
    try {
      const book = await importBook(launched.page, {
        fixturePath: AZW3_FIXTURE,
        kind: 'azw3',
        title: 'AZW3 TOC Test'
      })
      const bookPage = await openBook(launched.page, book.id)

      // Wait for the reader to mount before invoking the menu (so the
      // book-window context is registered in main).
      const counter = bookPage.locator('text=/^\\d+\\s*\\/\\s*\\d+$/').first()
      await counter.waitFor({ state: 'visible', timeout: 20000 })
      await bookPage.bringToFront()
      await bookPage.waitForTimeout(300)

      const clicked = await clickMenuItem(launched.app, ['View', 'Show TOC'])
      expect(clicked).toBe(true)

      // ReaderTOC renders a Radix Sheet. Either a panel with role=dialog or
      // the document containing the "Contents" / chapter list shows up.
      const sheet = bookPage.locator('[data-slot="sheet-content"]').first()
      await sheet.waitFor({ state: 'visible', timeout: 5000 })
    } finally {
      await closeApp(launched)
    }
  })

  test('Bookmarks > Add Bookmark stores a bookmark in the DB', async () => {
    test.setTimeout(60000)
    const launched = await launchApp()
    try {
      const book = await importBook(launched.page, {
        fixturePath: AZW3_FIXTURE,
        kind: 'azw3',
        title: 'AZW3 Bookmark Test'
      })

      // Seed syncId BEFORE opening the book window — Azw3View fetches
      // booksGetSyncId once on mount and caches the result in a ref. If
      // the syncId arrives after mount, the bookmark handler stays null
      // for the lifetime of that window.
      const syncId = await launched.page.evaluate(async (id) => {
        const e = (window as unknown as { electron: Record<string, Function> }).electron
        const existing = (await e.booksGetSyncId(id)) as string | null
        if (existing) return existing
        const row = (await e.getBook(id)) as Record<string, unknown> | null
        if (!row) return null
        const newId = `azw3-bm-${Date.now()}`
        await e.saveBook({ ...row, id, syncId: newId })
        return newId
      }, book.id)
      expect(syncId).toBeTruthy()

      const bookPage = await openBook(launched.page, book.id)

      const counter = bookPage.locator('text=/^\\d+\\s*\\/\\s*\\d+$/').first()
      await counter.waitFor({ state: 'visible', timeout: 20000 })
      await bookPage.bringToFront()
      await bookPage.waitForTimeout(800)

      const before = (await bookPage.evaluate(async (s) => {
        const e = (window as unknown as { electron: Record<string, Function> }).electron
        const list = (await e.bookmarksList(s)) as unknown[]
        return list.length
      }, syncId)) as number

      // Focus race: macOS Playwright sometimes loses focus on the book
      // window between bringToFront() and the menu click. Retry until the
      // bookmark count moves (or give up after a few attempts).
      let after = before
      for (let attempt = 0; attempt < 5 && after === before; attempt++) {
        await launched.app
          .evaluate(
            ({ BrowserWindow }, { url }) => {
              const win = BrowserWindow.getAllWindows().find((w) =>
                w.webContents.getURL().includes(url)
              )
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
        await launched.page.waitForTimeout(800)
        after = (await bookPage.evaluate(async (s) => {
          const e = (window as unknown as { electron: Record<string, Function> }).electron
          const list = (await e.bookmarksList(s)) as unknown[]
          return list.length
        }, syncId)) as number
      }

      expect(after).toBe(before + 1)
    } finally {
      await closeApp(launched)
    }
  })
})
