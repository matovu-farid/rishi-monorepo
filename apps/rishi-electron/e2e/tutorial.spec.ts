import { test, expect } from '@playwright/test'
import { closeApp, launchApp, type LaunchedApp } from './helpers/electron-app'

test.describe('Onboarding tour', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp({ keepOnboarding: true })
  })

  test.afterAll(async () => {
    await closeApp(app)
  })

  test.beforeEach(async () => {
    await app.page.evaluate(() => {
      localStorage.removeItem('rishi:tour-completed')
      localStorage.removeItem('rishi:hints-seen')
      localStorage.removeItem('rishi:welcome-seen')
    })
    await app.page.reload()
    await app.page.waitForTimeout(1500)
    // Tour only begins once the welcome modal is dismissed.
    const maybeLater = app.page.locator('text=Maybe later').first()
    if (await maybeLater.isVisible({ timeout: 2000 }).catch(() => false)) {
      await maybeLater.click()
    }
    await app.page.waitForTimeout(800)
  })

  test('first step targets the Add Books area', async () => {
    await expect(app.page.locator('[data-tour="import-books"]')).toBeAttached()
    await expect(app.page.locator('text=Add Your Books')).toBeVisible({ timeout: 5000 })
    await expect(app.page.locator('text=/1 of \\d+/')).toBeVisible()
  })

  test('Next advances to the second step', async () => {
    await expect(app.page.locator('text=Add Your Books')).toBeVisible({ timeout: 5000 })
    await app.page.locator('text=Next').first().click()
    await expect(app.page.locator('text=Your Library')).toBeVisible({ timeout: 5000 })
    await expect(app.page.locator('text=/2 of \\d+/')).toBeVisible()
  })

  test('Skip dismisses the tour and persists completion', async () => {
    await expect(app.page.locator('text=Add Your Books')).toBeVisible({ timeout: 5000 })
    await app.page.locator('text=Skip').first().click()
    await expect(app.page.locator('text=Add Your Books')).toHaveCount(0)
    const flag = await app.page.evaluate(() => localStorage.getItem('rishi:tour-completed'))
    expect(flag).toBe('1')
  })

  test('completed tour does not relaunch on next visit', async () => {
    await app.page.evaluate(() => {
      localStorage.setItem('rishi:tour-completed', '1')
    })
    await app.page.reload()
    await app.page.waitForTimeout(800)
    await expect(app.page.locator('text=Add Your Books')).toHaveCount(0)
  })
})
