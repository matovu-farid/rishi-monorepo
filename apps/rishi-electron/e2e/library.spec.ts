import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Library', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await deleteAllBooks(app.page)
    await app.page.evaluate(() => {
      window.location.hash = '#/'
    })
    await app.page.waitForTimeout(500)
  })

  test('search input accepts and clears text', async () => {
    const input = app.page.locator('input[placeholder*="Search"]')
    await input.fill('Machine Learning')
    await expect(input).toHaveValue('Machine Learning')
    await input.fill('')
    await expect(input).toHaveValue('')
  })

  test('imported book appears in library and opens reader', async () => {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Library Open Test'
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)

    // Phase 3: book rows are <button>s that spawn a new BrowserWindow.
    // Click the row's cover button — the wrapping <div> that contains the
    // title is the grid cell; the button is its first child.
    await expect(app.page.locator('text=Library Open Test').first()).toBeVisible({
      timeout: 10000
    })
    await app.page
      .locator('[data-tour="book-grid"] > div', { hasText: 'Library Open Test' })
      .locator('button')
      .first()
      .click()
    // Poll the shared context for the new book window.
    const ctx = app.page.context()
    const deadline = Date.now() + 10000
    let opened = false
    while (Date.now() < deadline) {
      if (ctx.pages().some((p) => p.url().includes(`/books/${book.id}`))) {
        opened = true
        break
      }
      await app.page.waitForTimeout(100)
    }
    expect(opened, 'a book window for the imported id should appear').toBe(true)
  })

  test('search filters book list by title', async () => {
    await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Library Alpha Filter'
    })
    await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Library Beta Filter'
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)

    await expect(app.page.locator('text=Library Alpha Filter')).toBeVisible({ timeout: 10000 })
    await expect(app.page.locator('text=Library Beta Filter')).toBeVisible()

    await app.page.locator('input[placeholder*="Search"]').fill('Alpha')
    await app.page.waitForTimeout(300)
    await expect(app.page.locator('text=Library Alpha Filter')).toBeVisible()
    await expect(app.page.locator('text=Library Beta Filter')).toHaveCount(0)

    await app.page.locator('input[placeholder*="Search"]').fill('')
    await app.page.waitForTimeout(300)
    await expect(app.page.locator('text=Library Beta Filter')).toBeVisible()
  })

  test('right-click context menu deletes a book', async () => {
    await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Library Right Click Delete'
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)

    const titleLocator = app.page.locator('text=Library Right Click Delete').first()
    await expect(titleLocator).toBeVisible({ timeout: 10000 })
    await titleLocator.click({ button: 'right' })
    const del = app.page.getByRole('button', { name: 'Delete' })
    await expect(del).toBeVisible({ timeout: 5000 })
    await del.click()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('text=Library Right Click Delete')).toHaveCount(0)
  })

  test('book grid uses data-tour="book-grid"', async () => {
    await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Library Grid Test'
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('[data-tour="book-grid"]')).toBeVisible({ timeout: 10000 })
  })
})
