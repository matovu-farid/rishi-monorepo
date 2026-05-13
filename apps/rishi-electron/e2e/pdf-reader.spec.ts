import { test, expect, type Page } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('PDF reader', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'PDF Reader Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    bookPage = await openBook(app.page, bookId)
    await bookPage.waitForTimeout(3000)
  })

  test('voice chat launcher is present', async () => {
    await expect(bookPage.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('TTS orb is present', async () => {
    await expect(bookPage.locator('[aria-label="Expand TTS controls"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('keyboard navigation does not crash', async () => {
    await bookPage.keyboard.press('ArrowRight')
    await bookPage.waitForTimeout(300)
    await bookPage.keyboard.press('ArrowLeft')
    await bookPage.waitForTimeout(300)
    await expect(bookPage.locator('body')).toBeVisible()
  })

  test('invalid book id does not crash the app', async () => {
    // The route guard now intercepts library hash changes to /books/N and
    // spawns a window instead, so this test exercises the legacy hash on
    // the library page directly to ensure nothing crashes.
    await app.page.evaluate(() => {
      window.location.hash = '#/books/999999'
    })
    await app.page.waitForTimeout(2000)
    await expect(app.page.locator('body')).toBeVisible()
  })
})
