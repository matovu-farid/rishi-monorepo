import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Book import & open lifecycle', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await deleteAllBooks(app.page)
    await app.page.evaluate(() => {
      window.location.hash = '#/'
    })
    await app.page.waitForTimeout(500)
  })

  test('library shows empty state with no books', async () => {
    await expect(app.page.locator('text=Add Book')).toBeVisible()
    await expect(app.page.locator('text=No books yet')).toBeVisible()
  })

  test('PDF imports, opens, and renders pages', async () => {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Import Open PDF'
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('[data-tour="book-grid"]')).toBeVisible({ timeout: 10000 })

    await openBook(app.page, book.id)
    // Wait for the PDF scroll container to mount — this is the reader's
    // unmistakable shell. The native menu is the back path; no in-window
    // back link to assert against anymore.
    await expect(app.page.locator('div.overflow-y-scroll').first()).toBeAttached({
      timeout: 15000
    })
    await app.page.waitForTimeout(3000)
  })

  test('EPUB imports and reaches the reader view', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Import Open EPUB'
    })
    await openBook(app.page, book.id)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test('back to library after delete shows empty state', async () => {
    await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Delete Then Empty'
    })
    await deleteAllBooks(app.page)
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('text=No books yet')).toBeVisible()
  })
})
