import { test, expect, type Page } from '@playwright/test'
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

test.describe('Text-to-speech controls', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'TTS Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await closeOverlays(app.page)
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Expand TTS controls"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('orb is fixed-position bottom-right', async () => {
    const orb = bookPage.locator('[aria-label="Expand TTS controls"]')
    await expect(orb).toHaveCSS('position', 'fixed')
  })

  test('expanding the orb reveals Play / Previous / Next / Stop', async () => {
    await bookPage.locator('[aria-label="Expand TTS controls"]').click()
    await expect(bookPage.locator('[aria-label="Play"]')).toBeVisible({ timeout: 5000 })
    await expect(bookPage.locator('[aria-label="Previous"]')).toBeVisible()
    await expect(bookPage.locator('[aria-label="Next"]')).toBeVisible()
    await expect(bookPage.locator('[aria-label="Stop"]')).toBeVisible()
  })

  test('Stop is disabled when nothing is playing', async () => {
    await bookPage.locator('[aria-label="Expand TTS controls"]').click()
    await expect(bookPage.locator('[aria-label="Stop"]')).toBeDisabled()
  })

  test('Play without auth opens premium dialog', async () => {
    await bookPage.locator('[aria-label="Expand TTS controls"]').click()
    await bookPage.locator('[aria-label="Play"]').click()
    await expect(bookPage.locator("[data-slot='dialog-content']")).toBeVisible({ timeout: 5000 })
    await expect(bookPage.locator('text=Sign in').first()).toBeVisible()
    await bookPage.locator('text=Maybe later').first().click()
    await expect(bookPage.locator("[data-slot='dialog-content']")).toHaveCount(0)
  })
})
