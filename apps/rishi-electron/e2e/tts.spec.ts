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

test.describe('Text-to-speech controls', () => {
  let app: LaunchedApp
  let bookId: number

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
    await openBook(app.page, bookId)
    await expect(app.page.locator('[aria-label="Expand TTS controls"]').first()).toBeVisible({
      timeout: 15000
    })
  })

  test('orb is fixed-position bottom-right', async () => {
    const orb = app.page.locator('[aria-label="Expand TTS controls"]')
    await expect(orb).toHaveCSS('position', 'fixed')
  })

  test('expanding the orb reveals Play / Previous / Next / Stop', async () => {
    await app.page.locator('[aria-label="Expand TTS controls"]').click()
    await expect(app.page.locator('[aria-label="Play"]')).toBeVisible({ timeout: 5000 })
    await expect(app.page.locator('[aria-label="Previous"]')).toBeVisible()
    await expect(app.page.locator('[aria-label="Next"]')).toBeVisible()
    await expect(app.page.locator('[aria-label="Stop"]')).toBeVisible()
  })

  test('Stop is disabled when nothing is playing', async () => {
    await app.page.locator('[aria-label="Expand TTS controls"]').click()
    await expect(app.page.locator('[aria-label="Stop"]')).toBeDisabled()
  })

  test('Play without auth opens premium dialog', async () => {
    await app.page.locator('[aria-label="Expand TTS controls"]').click()
    await app.page.locator('[aria-label="Play"]').click()
    await expect(app.page.locator("[data-slot='dialog-content']")).toBeVisible({ timeout: 5000 })
    await expect(app.page.locator('text=Sign in').first()).toBeVisible()
    await app.page.locator('text=Maybe later').first().click()
    await expect(app.page.locator("[data-slot='dialog-content']")).toHaveCount(0)
  })
})
