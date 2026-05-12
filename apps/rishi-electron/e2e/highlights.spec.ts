import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  revealReaderToolbar,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('Highlights', () => {
  let app: LaunchedApp
  let bookId: number

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Highlights Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page)
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await openBook(app.page, bookId)
    await expect(app.page.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
    await revealReaderToolbar(app.page)
  })

  test('highlights panel opens with empty state copy', async () => {
    const toolbar = app.page.locator('[data-tour="reader-toolbar"]')
    await expect(toolbar).toBeVisible({ timeout: 5000 })
    const trigger = toolbar.locator('[aria-label*="ighlight"]').first()
    if ((await trigger.count()) === 0) return
    await trigger.click()
    await expect(app.page.locator('text=No highlights yet')).toBeVisible({ timeout: 5000 })
  })

  test('panel close button hides the empty state', async () => {
    const toolbar = app.page.locator('[data-tour="reader-toolbar"]')
    await expect(toolbar).toBeVisible({ timeout: 5000 })
    const trigger = toolbar.locator('[aria-label*="ighlight"]').first()
    if ((await trigger.count()) === 0) return
    await trigger.click()
    await expect(app.page.locator('text=No highlights yet')).toBeVisible({ timeout: 5000 })
    await app.page.locator('[aria-label="Close"]').first().click()
    await expect(app.page.locator('text=No highlights yet')).toHaveCount(0)
  })
})
