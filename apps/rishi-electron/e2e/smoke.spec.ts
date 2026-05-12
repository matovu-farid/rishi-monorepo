import { test, expect } from '@playwright/test'
import { closeApp, launchApp, type LaunchedApp } from './helpers/electron-app'

test.describe('Smoke', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test('app boots and shows library shell', async () => {
    await expect(app.page.locator('button', { hasText: /^Add Book$/ }).first()).toBeVisible()
    await expect(app.page.locator('input[placeholder*="Search"]')).toBeVisible()
    await expect(app.page.locator('button', { hasText: /^Login$/ }).first()).toBeVisible()
  })

  test('library starts empty', async () => {
    await expect(app.page.locator('text=No books yet')).toBeVisible()
    await expect(app.page.locator('text=drag and drop')).toBeVisible()
  })

  test('preload exposes core IPC surface', async () => {
    const surface = await app.page.evaluate(() => {
      const e = (window as unknown as { electron: Record<string, unknown> }).electron
      const required = [
        'getBooks',
        'getBook',
        'saveBook',
        'deleteBook',
        'updateBookLocation',
        'getPdfData',
        'getBookData',
        'getAppDataPath',
        'copyFile',
        'readFile',
        'exists'
      ]
      return required.map((k) => ({ k, ok: typeof e?.[k] === 'function' }))
    })
    for (const { k, ok } of surface) {
      expect(ok, `electron.${k} missing`).toBe(true)
    }
  })
})
