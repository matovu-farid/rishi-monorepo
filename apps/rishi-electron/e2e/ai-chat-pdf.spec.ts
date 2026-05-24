import { test, expect, type Page } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  closeOverlays,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Parity coverage for the PDF reader's voice-chat launcher (#233).
 *
 * The launcher's auth gate fires BEFORE the chat-activation subscription, so
 * the premium dialog appears on click regardless of the underlying
 * subscription wiring — this spec therefore mainly guards the observable
 * surface (button present, dialog opens, "Maybe later" dismisses). The real
 * regression guard for the missing subscription lives in pdfStore.test.ts
 * (`voice chat activation (#233)`).
 *
 * Mirrors the EPUB version in `ai-chat.spec.ts` exactly so any future drift
 * between the two reader paths is immediately visible.
 */
test.describe('Voice chat / premium gate (PDF)', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Voice Chat PDF Spec'
    })
    bookId = book.id
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await closeOverlays(bookPage)
  })

  test('voice chat launcher renders in the pdf reader', async () => {
    await expect(bookPage.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('clicking voice chat without auth opens the premium dialog', async () => {
    await bookPage.locator('[aria-label="Start voice chat"]').first().click()
    const dialog = bookPage.locator("[data-slot='dialog-content']")
    await expect(dialog).toBeVisible({ timeout: 5000 })
    await expect(dialog.locator('text=Sign in').first()).toBeVisible()
  })

  test('"Maybe later" closes the premium dialog', async () => {
    await bookPage.locator('[aria-label="Start voice chat"]').first().click()
    await expect(bookPage.locator("[data-slot='dialog-content']")).toBeVisible({ timeout: 5000 })
    await bookPage.locator('text=Maybe later').first().click()
    await expect(bookPage.locator("[data-slot='dialog-content']")).toHaveCount(0)
  })
})
