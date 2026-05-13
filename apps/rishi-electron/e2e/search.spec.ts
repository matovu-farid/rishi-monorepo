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
    const result = await app.page.evaluate(
      async (id) => {
        const e = (window as unknown as { electron: Record<string, Function> }).electron
        try {
          const r = await e.searchBookText('the', id)
          return Array.isArray(r)
        } catch {
          return false
        }
      },
      bookId
    )
    expect(result).toBe(true)
  })
})
