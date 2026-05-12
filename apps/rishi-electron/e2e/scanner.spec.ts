import { test, expect } from '@playwright/test'
import { closeApp, launchApp, type LaunchedApp } from './helpers/electron-app'

test.describe('Book scanner / discovery modal', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await app.page.keyboard.press('Escape')
    await app.page.waitForTimeout(200)
    const modalText = app.page.locator('text=Common folders')
    if ((await modalText.count()) > 0) {
      const cancel = app.page.locator('button', { hasText: /^Cancel$/ }).first()
      if (await cancel.isVisible({ timeout: 500 }).catch(() => false)) await cancel.click()
      await app.page.waitForTimeout(300)
    }
    await app.page.evaluate(() => {
      window.location.hash = '#/'
    })
    await app.page.waitForTimeout(300)
  })

  test('Add Book opens the discovery modal with scan controls', async () => {
    await app.page.locator('button', { hasText: /^Add Book$/ }).first().click()
    await expect(app.page.locator('text=Common folders')).toBeVisible({ timeout: 10000 })
    await expect(app.page.locator('text=Search entire computer')).toBeVisible()
    await expect(app.page.locator('input[placeholder*="Filter"]')).toBeVisible({ timeout: 10000 })
  })

  test('discovery modal shows a scanning indicator', async () => {
    await app.page.locator('button', { hasText: /^Add Book$/ }).first().click()
    await expect(app.page.locator('text=/Scanning/i').first()).toBeVisible({ timeout: 10000 })
  })

  test('Cancel closes the discovery modal', async () => {
    await app.page.locator('button', { hasText: /^Add Book$/ }).first().click()
    await expect(app.page.locator('text=Common folders')).toBeVisible({ timeout: 10000 })
    await app.page.locator('button', { hasText: /^Cancel$/ }).first().click()
    await expect(app.page.locator('text=Common folders')).toHaveCount(0)
  })
})
