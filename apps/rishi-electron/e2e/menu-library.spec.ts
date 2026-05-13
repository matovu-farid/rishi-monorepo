import { test, expect } from '@playwright/test'
import { launchApp, closeApp, getApplicationMenu, findMenuItem } from './helpers/electron-app'

test('library window menu has File/Edit/View/Window/Help but no Bookmarks/Reader', async () => {
  const launched = await launchApp()
  try {
    const menu = await getApplicationMenu(launched.app)
    const labels = menu.map((m) => m.label)
    expect(labels).toEqual(expect.arrayContaining(['File', 'Edit', 'View', 'Window', 'Help']))
    expect(labels).not.toContain('Bookmarks')
    expect(labels).not.toContain('Reader')

    expect(findMenuItem(menu, ['File', 'Import Book…'])).toBeDefined()
    expect(findMenuItem(menu, ['Window', 'Library'])?.accelerator).toMatch(/Cmd|Ctrl/)
  } finally {
    await closeApp(launched)
  }
})
