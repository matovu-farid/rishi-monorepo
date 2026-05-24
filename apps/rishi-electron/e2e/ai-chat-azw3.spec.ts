import { test, expect, type Page } from '@playwright/test'
import {
  AZW3_FIXTURE,
  MOBI_FIXTURE,
  closeApp,
  closeOverlays,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Parity coverage for the AZW3/MOBI reader's voice-chat launcher (#237).
 *
 * Same caveat as the PDF version (`ai-chat-pdf.spec.ts`): the launcher's
 * auth gate fires BEFORE the chat-activation subscription, so the premium
 * dialog appears on click regardless of the underlying subscription wiring.
 * This spec therefore mainly guards the observable surface (launcher present,
 * dialog opens, "Maybe later" dismisses). The real regression guard for the
 * missing subscription lives in:
 *   - src/renderer/src/components/azw3/Azw3View.chatActivation.test.tsx
 *   - src/renderer/src/stores/initBookChatSubscription.test.ts
 *
 * Mirrors the EPUB version in `ai-chat.spec.ts` and the PDF version in
 * `ai-chat-pdf.spec.ts` exactly so any future drift between the four reader
 * paths (EPUB, PDF, MOBI, AZW3) is immediately visible.
 *
 * Both MOBI and AZW3 flow through the same Azw3View renderer
 * (routes/books.$id.lazy.tsx:88,91-92), so we exercise both kinds against
 * the same set of assertions to prove the activation wiring is kind-agnostic.
 */

const fixtures = [
  { kind: 'azw3' as const, fixture: AZW3_FIXTURE, label: 'AZW3' },
  { kind: 'mobi' as const, fixture: MOBI_FIXTURE, label: 'MOBI' }
]

for (const { kind, fixture, label } of fixtures) {
  test.describe(`Voice chat / premium gate (${label})`, () => {
    let app: LaunchedApp
    let bookId: number
    let bookPage: Page

    test.beforeAll(async () => {
      app = await launchApp()
      const book = await importBook(app.page, {
        fixturePath: fixture,
        kind,
        title: `Voice Chat ${label} Spec`
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

    test(`voice chat launcher renders in the ${label} reader`, async () => {
      await expect(bookPage.locator('[aria-label="Start voice chat"]').first()).toBeVisible({
        timeout: 15000
      })
    })

    test(`clicking voice chat without auth opens the premium dialog (${label})`, async () => {
      await bookPage.locator('[aria-label="Start voice chat"]').first().click()
      const dialog = bookPage.locator("[data-slot='dialog-content']")
      await expect(dialog).toBeVisible({ timeout: 5000 })
      await expect(dialog.locator('text=Sign in').first()).toBeVisible()
    })

    test(`"Maybe later" closes the premium dialog (${label})`, async () => {
      await bookPage.locator('[aria-label="Start voice chat"]').first().click()
      await expect(bookPage.locator("[data-slot='dialog-content']")).toBeVisible({ timeout: 5000 })
      await bookPage.locator('text=Maybe later').first().click()
      await expect(bookPage.locator("[data-slot='dialog-content']")).toHaveCount(0)
    })
  })
}
