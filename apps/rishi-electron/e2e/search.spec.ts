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
    // `importBook` (e2e helper) only inserts the books row — it bypasses the
    // chunk-data / FTS indexing pipeline that real opens run via
    // useBookEmbeddings → indexBook → savePageDataMany. Seed a single chunk
    // here through the existing IPC so the FTS triggers populate
    // chunk_data_fts for `bookId`, then assert searchBookText finds it.
    // This keeps the contract under test (the IPC + FTS5 wiring) rather
    // than the importer.
    await app.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      await e.savePageDataMany([
        {
          // Omit id so SQLite assigns AUTOINCREMENT — chunk_data_ai trigger
          // mirrors the row into chunk_data_fts using the new rowid.
          pageNumber: 1,
          bookId: id,
          data: 'The quick brown fox jumps over the lazy dog'
        }
      ])
    }, bookId)

    // Let the IPC throw propagate so failures carry the original stack instead
    // of being reduced to `Expected true / Received false`. 'fox' is in the
    // seeded chunk above, so a silent empty-array return (broken FTS) fails
    // the length assertion.
    const result = await app.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: Record<string, (...args: unknown[]) => unknown> })
        .electron
      return (await e.searchBookText('fox', id)) as unknown
    }, bookId)
    expect(Array.isArray(result)).toBe(true)
    expect((result as unknown[]).length).toBeGreaterThan(0)
  })
})
