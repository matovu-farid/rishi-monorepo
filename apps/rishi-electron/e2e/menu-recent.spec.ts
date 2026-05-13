import { test, expect } from '@playwright/test'
import {
  launchApp,
  closeApp,
  importBook,
  PDF_FIXTURE,
  getApplicationMenu,
  findMenuItem,
  clickMenuItem
} from './helpers/electron-app'

test('File > Open Recent lists imported books and opens them', async () => {
  const launched = await launchApp()
  try {
    // Explicitly focus the library window so `clickMenuItem` dispatches to
    // the right webContents (parallel workers can race for focus otherwise).
    await launched.app.evaluate(({ BrowserWindow }) => {
      const win = BrowserWindow.getAllWindows()[0]
      if (!win) return
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    })
    await launched.page.waitForTimeout(200)

    const a = await importBook(launched.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Recent A'
    })
    expect(a.id).toBeGreaterThan(0)
    await launched.page.waitForTimeout(500)

    // Trigger a menu rebuild so Open Recent picks up the freshly-imported
    // book. In production the library renderer fires this after every
    // successful import; here we call it directly to avoid relying on
    // platform-specific window focus behavior.
    await launched.page.evaluate(() => {
      const e = (window as unknown as { electron: { refreshMenu(): void } }).electron
      e.refreshMenu()
    })
    await launched.page.waitForTimeout(400)

    const menu = await getApplicationMenu(launched.app)
    const recent = findMenuItem(menu, ['File', 'Open Recent'])
    expect(recent?.submenu?.some((m) => m.label === 'Recent A')).toBe(true)

    const before = launched.app.windows().length
    expect(await clickMenuItem(launched.app, ['File', 'Open Recent', 'Recent A'])).toBe(true)
    await launched.page.waitForTimeout(1800)
    expect(launched.app.windows().length).toBeGreaterThan(before)
  } finally {
    await closeApp(launched)
  }
})
