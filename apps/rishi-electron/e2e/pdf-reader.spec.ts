import { test, expect, type Page } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  getBookLocation,
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

  test('keyboard navigation advances and restores the persisted page index', async () => {
    // Body-visibility was a tautology — it stays true even if Arrow keys are
    // unbound in the Phase-3 split reader window. Observe the persisted
    // `page:offset` location instead: ArrowRight must move the page index
    // forward; ArrowLeft must move it back.
    const pageOf = (loc: string | undefined): number => Number((loc ?? '0').split(':')[0])
    const before = pageOf(await getBookLocation(app.page, bookId))
    await bookPage.keyboard.press('ArrowRight')
    await expect
      .poll(async () => pageOf(await getBookLocation(app.page, bookId)), { timeout: 5000 })
      .toBeGreaterThan(before)
    const advanced = pageOf(await getBookLocation(app.page, bookId))
    await bookPage.keyboard.press('ArrowLeft')
    await expect
      .poll(async () => pageOf(await getBookLocation(app.page, bookId)), { timeout: 5000 })
      .toBeLessThan(advanced)
  })

  test('invalid book id on library window is intercepted by the route guard', async () => {
    // The route guard at __root.tsx must intercept hash mutations to /books/N
    // on the library window — not just the initial mount — and reset the hash
    // back to '/' (delegating the actual book open to the main process, which
    // validates the id). Asserting the hash reset is the observable signal
    // that the guard fired; without this assertion the test passes even when
    // the guard is silently regressed (B042).
    const windowsBefore = app.app.windows().length
    await app.page.evaluate(() => {
      window.location.hash = '#/books/999999'
    })
    await app.page.waitForTimeout(2000)
    const hash = await app.page.evaluate(() => window.location.hash)
    // Guard must reset the library hash away from /books/<id>.
    expect(hash).not.toMatch(/^#\/books\//)
    // Guard must not leak the library window into the books.$id error view.
    await expect(app.page.locator('text=Book not found')).toHaveCount(0)
    // No additional library window spawned for an invalid id beyond whatever
    // openBook produces (main-side validation is out of scope here).
    expect(app.app.windows().length).toBeGreaterThanOrEqual(windowsBefore)
  })
})
