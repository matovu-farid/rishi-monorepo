import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  getBookLocation,
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

  test('next-page click advances the persisted CFI', async () => {
    const before = await getBookLocation(app.page, bookId)
    await bookPage.locator('[aria-label="Next page"]').first().click()
    // EPUB location persists via updateBookLocation IPC on relocated; poll
    // the DB-backed location until it differs from `before`. This catches
    // swallowed errors / no-op handlers that leave the toolbar intact.
    await expect
      .poll(async () => await getBookLocation(app.page, bookId), { timeout: 5000 })
      .not.toBe(before)
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

  test('keyboard arrows change the persisted CFI', async () => {
    const start = await getBookLocation(app.page, bookId)
    await bookPage.locator('[aria-label="Next page"]').first().click()
    await expect
      .poll(async () => await getBookLocation(app.page, bookId), { timeout: 5000 })
      .not.toBe(start)
    const afterNext = await getBookLocation(app.page, bookId)
    await bookPage.keyboard.press('ArrowLeft')
    await expect
      .poll(async () => await getBookLocation(app.page, bookId), { timeout: 5000 })
      .not.toBe(afterNext)
    const afterLeft = await getBookLocation(app.page, bookId)
    await bookPage.keyboard.press('ArrowRight')
    await expect
      .poll(async () => await getBookLocation(app.page, bookId), { timeout: 5000 })
      .not.toBe(afterLeft)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()
  })

  test('rapid forward navigation advances the persisted CFI', async () => {
    const start = await getBookLocation(app.page, bookId)
    for (let i = 0; i < 5; i++) {
      // eslint-disable-next-line no-await-in-loop -- E2E test: each click depends on the previous page transition completing.
      await bookPage.locator('[aria-label="Next page"]').first().click()
      // eslint-disable-next-line no-await-in-loop -- E2E test: settle between rapid navigations.
      await bookPage.waitForTimeout(200)
    }
    // After 5 clicks the persisted CFI must differ from the starting point.
    // body-visible was a tautology — this catches a swallowed-error handler.
    await expect
      .poll(async () => await getBookLocation(app.page, bookId), { timeout: 5000 })
      .not.toBe(start)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible()
  })
})
