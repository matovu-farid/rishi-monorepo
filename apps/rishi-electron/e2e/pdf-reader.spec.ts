import { test, expect } from '@playwright/test'
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
    await openBook(app.page, bookId)
    await app.page.waitForTimeout(3000)
  })

  test('back link to library exists', async () => {
    await expect(app.page.locator('a[href="/#/"]').first()).toBeVisible({ timeout: 15000 })
  })

  test('reader toolbar is mounted', async () => {
    await expect(app.page.locator('[data-tour="reader-toolbar"]').first()).toBeAttached({
      timeout: 15000
    })
  })

  test('voice chat launcher is present', async () => {
    await expect(app.page.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('TTS orb is present', async () => {
    await expect(app.page.locator('[aria-label="Expand TTS controls"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('keyboard navigation does not crash', async () => {
    await app.page.keyboard.press('ArrowRight')
    await app.page.waitForTimeout(300)
    await app.page.keyboard.press('ArrowLeft')
    await app.page.waitForTimeout(300)
    await expect(app.page.locator('body')).toBeVisible()
  })

  test('invalid book id does not crash the app', async () => {
    await app.page.evaluate(() => {
      window.location.hash = '#/books/999999'
    })
    await app.page.waitForTimeout(2000)
    await expect(app.page.locator('body')).toBeVisible()
  })
})
