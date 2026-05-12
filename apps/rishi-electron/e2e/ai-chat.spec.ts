import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  closeOverlays,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Voice chat / premium gate', () => {
  let app: LaunchedApp
  let bookId: number

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Voice Chat Spec'
    })
    bookId = book.id
    await openBook(app.page, bookId)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await closeOverlays(app.page)
  })

  test('voice chat launcher renders in the reader', async () => {
    await expect(app.page.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('clicking voice chat without auth opens the premium dialog', async () => {
    await app.page.locator('[aria-label="Start voice chat"]').first().click()
    const dialog = app.page.locator("[data-slot='dialog-content']")
    await expect(dialog).toBeVisible({ timeout: 5000 })
    await expect(dialog.locator('text=Sign in').first()).toBeVisible()
  })

  test('"Maybe later" closes the premium dialog', async () => {
    await app.page.locator('[aria-label="Start voice chat"]').first().click()
    await expect(app.page.locator("[data-slot='dialog-content']")).toBeVisible({ timeout: 5000 })
    await app.page.locator('text=Maybe later').first().click()
    await expect(app.page.locator("[data-slot='dialog-content']")).toHaveCount(0)
  })
})
