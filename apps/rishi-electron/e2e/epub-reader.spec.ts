import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  getBookLocation,
  importBook,
  launchApp,
  openBook,
  sendMenuCommandToBookWindow,
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
    // The "Next page" button can paint before the rendition has settled
    // (settledRef.current = true only after `relocated` fires + locations
    // generate). Clicking before settle means the locationChanged handler's
    // `if (settledRef && userNavHappened)` gate drops the save, so the
    // persisted CFI never changes. Wait for the store-side CFI to publish
    // before any test interacts.
    await bookPage.waitForFunction(
      () => {
        const w = window as unknown as {
          __rishi?: { epubStore?: { getState: () => { currentEpubLocation: string } } }
        }
        const cfi = w.__rishi?.epubStore?.getState().currentEpubLocation
        return !!cfi && cfi.startsWith('epubcfi(')
      },
      undefined,
      { timeout: 30000 }
    )
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
    // The EPUB reader does not render a visible TOC toggle button — the TOC is
    // a `<Sheet>` (ReaderTOC) controlled by the `toggleTOC` menu command
    // (View > Show TOC, ⌘T). Dispatch it directly via the same `menu:command`
    // IPC the native menu uses, so the test doesn't need OS focus to land on
    // the right window.
    const dispatched1 = await sendMenuCommandToBookWindow(app.app, bookId, 'toggleTOC')
    expect(dispatched1).toBe(true)
    await expect(bookPage.locator('text=Table of Contents').first()).toBeVisible({ timeout: 5000 })

    const dispatched2 = await sendMenuCommandToBookWindow(app.app, bookId, 'toggleTOC')
    expect(dispatched2).toBe(true)
    // The Sheet animates closed via Framer Motion AnimatePresence; wait until
    // the title text is gone from the DOM rather than asserting it's hidden.
    await expect(bookPage.locator('text=Table of Contents')).toHaveCount(0, { timeout: 5000 })
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
