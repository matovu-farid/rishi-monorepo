import { test, expect } from '@playwright/test'
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
    await openBook(app.page, bookId)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test('renders prev and next page arrows', async () => {
    await expect(app.page.locator('[aria-label="Previous page"]').first()).toBeVisible()
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('next-page click does not crash', async () => {
    await app.page.locator('[aria-label="Next page"]').first().click()
    await app.page.waitForTimeout(500)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('TOC toggle opens and closes the table of contents', async () => {
    const tocToggle = app.page.locator('[aria-label="Toggle table of contents"]').first()
    if ((await tocToggle.count()) === 0) test.skip(true, 'no TOC toggle in this build')
    await tocToggle.click()
    await expect(app.page.locator('text=Table of Contents').first()).toBeVisible({ timeout: 5000 })
    await tocToggle.click()
    await expect(app.page.locator('text=Table of Contents')).toHaveCount(0)
  })

  test('keyboard arrows navigate without crashing', async () => {
    await app.page.locator('[aria-label="Next page"]').first().click()
    await app.page.keyboard.press('ArrowLeft')
    await app.page.waitForTimeout(200)
    await app.page.keyboard.press('ArrowRight')
    await app.page.waitForTimeout(200)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('rapid forward navigation does not crash', async () => {
    for (let i = 0; i < 5; i++) {
      await app.page.locator('[aria-label="Next page"]').first().click()
      await app.page.waitForTimeout(200)
    }
    await expect(app.page.locator('body')).toBeVisible()
  })
})
