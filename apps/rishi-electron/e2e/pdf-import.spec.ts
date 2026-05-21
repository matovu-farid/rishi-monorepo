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

    const bookPage = await openBook(app.page, book.id)
    // The test name promises "renders pages" — assert on the actual rendered
    // surface (canvas emitted by react-pdf's Page), not just the scroll shell.
    // A blank-canvas / pdfjs worker failure would mount the shell but emit no
    // canvas, which the previous toBeAttached on div.overflow-y-scroll missed.
    await expect(bookPage.locator('canvas.react-pdf__Page__canvas').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('EPUB imports and reaches the reader view', async () => {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Import Open EPUB'
    })
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
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
