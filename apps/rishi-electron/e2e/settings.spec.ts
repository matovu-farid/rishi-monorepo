import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  closeOverlays,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  revealReaderToolbar,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Reader settings', () => {
  let app: LaunchedApp
  let bookId: number

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Settings Spec'
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
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await revealReaderToolbar(app.page)
  })

  test('settings popover shows Font Size and Font Family controls', async () => {
    await app.page.locator('[aria-label="Reader settings"]').first().click()
    await expect(app.page.locator('text=Font Size')).toBeVisible()
    await expect(app.page.locator('text=Font Family')).toBeVisible()
    await expect(app.page.locator('text=Serif')).toBeVisible()
    await expect(app.page.locator('text=Sans')).toBeVisible()
  })

  test('font size slider is bounded 0.8 → 2', async () => {
    await app.page.locator('[aria-label="Reader settings"]').first().click()
    const slider = app.page.locator('input[type="range"]').first()
    await expect(slider).toHaveAttribute('min', '0.8')
    await expect(slider).toHaveAttribute('max', '2')
  })

  test('settings persist to localStorage when changed', async () => {
    await app.page.locator('[aria-label="Reader settings"]').first().click()
    await app.page.locator('text=Serif').first().click()
    await app.page.waitForTimeout(200)
    const raw = await app.page.evaluate(() => localStorage.getItem('rishi:reader-settings'))
    expect(raw).toBeTruthy()
    const parsed = JSON.parse(raw as string)
    expect(parsed).toHaveProperty('fontFamily')
  })
})
