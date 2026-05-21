import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Search', () => {
  let app: LaunchedApp
  let bookId: number

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Search Spec EPUB'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test('library search input round-trips text', async () => {
    await app.page.evaluate(() => {
      window.location.hash = '#/'
    })
    await app.page.waitForTimeout(300)
    const input = app.page.locator('input[placeholder*="Search"]')
    await input.fill('Machine Learning')
    await expect(input).toHaveValue('Machine Learning')
    await input.fill('')
    await expect(input).toHaveValue('')
  })

  test('searchBookText IPC accepts a query', async () => {
    // Let the IPC throw propagate so failures carry the original stack instead
    // of being reduced to `Expected true / Received false`. The stop-word
    // 'the' is certain to appear at least once in any English EPUB fixture, so
    // a silent empty-array return (broken index) fails the length assertion.
    const result = await app.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return (await e.searchBookText('the', id)) as unknown
    }, bookId)
    expect(Array.isArray(result)).toBe(true)
    expect((result as unknown[]).length).toBeGreaterThan(0)
  })
})
