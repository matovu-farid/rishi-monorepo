import { test, expect } from '@playwright/test'
import { closeApp, launchApp, type LaunchedApp } from './helpers/electron-app'

test.describe('Auth surface', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test('Sign In control is reachable from the library', async () => {
    await app.page.evaluate(() => {
      window.location.hash = '#/'
    })
    await app.page.waitForTimeout(300)
    await expect(app.page.locator('text=Sign In').first()).toBeVisible({ timeout: 10000 })
  })

  test('welcome modal reappears after clearing localStorage', async () => {
    await app.page.evaluate(() => {
      localStorage.clear()
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('text=Welcome to Rishi')).toBeVisible({ timeout: 5000 })
    await expect(app.page.locator('text=Sign in').first()).toBeVisible()
  })

  test('"Maybe later" dismisses the welcome modal and persists', async () => {
    await app.page.evaluate(() => {
      localStorage.clear()
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('text=Welcome to Rishi')).toBeVisible({ timeout: 5000 })
    await app.page.locator('text=Maybe later').first().click()
    await expect(app.page.locator('text=Welcome to Rishi')).toHaveCount(0)
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    await expect(app.page.locator('text=Welcome to Rishi')).toHaveCount(0)
  })
})
