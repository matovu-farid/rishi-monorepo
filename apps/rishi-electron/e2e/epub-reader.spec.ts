import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('EPUB reader', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'EPUB Reader Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test('renders prev and next page arrows', async () => {
    await expect(bookPage.locator('[aria-label="Previous page"]').first()).toBeVisible()
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('next-page click does not crash', async () => {
    await bookPage.locator('[aria-label="Next page"]').first().click()
    await bookPage.waitForTimeout(500)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('TOC toggle opens and closes the table of contents', async () => {
    const tocToggle = bookPage.locator('[aria-label="Toggle table of contents"]').first()
    if ((await tocToggle.count()) === 0) test.skip(true, 'no TOC toggle in this build')
    await tocToggle.click()
    await expect(bookPage.locator('text=Table of Contents').first()).toBeVisible({ timeout: 5000 })
    await tocToggle.click()
    await expect(bookPage.locator('text=Table of Contents')).toHaveCount(0)
  })

  test('keyboard arrows navigate without crashing', async () => {
    await bookPage.locator('[aria-label="Next page"]').first().click()
    await bookPage.keyboard.press('ArrowLeft')
    await bookPage.waitForTimeout(200)
    await bookPage.keyboard.press('ArrowRight')
    await bookPage.waitForTimeout(200)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('rapid forward navigation does not crash', async () => {
    for (let i = 0; i < 5; i++) {
      // eslint-disable-next-line no-await-in-loop -- E2E test: each click depends on the previous page transition completing.
      await bookPage.locator('[aria-label="Next page"]').first().click()
      // eslint-disable-next-line no-await-in-loop -- E2E test: settle between rapid navigations.
      await bookPage.waitForTimeout(200)
    }
    await expect(bookPage.locator('body')).toBeVisible()
  })
})
