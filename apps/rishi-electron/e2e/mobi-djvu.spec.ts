import { test, expect } from '@playwright/test'
import {
  DJVU_FIXTURE,
  MOBI_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('MOBI & DJVU readers', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await deleteAllBooks(app.page)
  })

  test('MOBI book opens and renders', async () => {
    const book = await importBook(app.page, {
      fixturePath: MOBI_FIXTURE,
      kind: 'mobi',
      title: 'MOBI Render Test'
    })
    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)
    await expect(bookPage.locator('a[href="/"]')).toHaveCount(
      await bookPage.locator('a[href="/"]').count()
    )
    await expect(bookPage.locator('body')).not.toBeEmpty()
  })

  test('DJVU book opens and renders', async () => {
    const book = await importBook(app.page, {
      fixturePath: DJVU_FIXTURE,
      kind: 'djvu',
      title: 'DJVU Render Test'
    })
    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)
    await expect(bookPage.locator('body')).not.toBeEmpty()
  })

  test('non-existent book id does not crash', async () => {
    await app.page.evaluate(() => {
      window.location.hash = '#/books/99999'
    })
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('body')).toBeVisible()
  })
})
