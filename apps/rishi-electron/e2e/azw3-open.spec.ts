import { test, expect } from '@playwright/test'
import {
  AZW3_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook
} from './helpers/electron-app'

// TDD reproduction for AZW3 support. Mirrors what MOBI provides:
//   - opens via the book window
//   - renders chapter content in an iframe
//   - shows the "X / Y" chapter counter once the parser has reported the count
//
// AZW3 is the Kindle KF8 format — a PDB container (same as MOBI) wrapping a
// KF8 payload. Parsed via foliate-js's mobi module in the implementation.
test('AZW3 book opens and renders the first chapter', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: AZW3_FIXTURE,
      kind: 'azw3',
      title: 'AZW3 Render Test'
    })
    const bookPage = await openBook(launched.page, book.id)

    // Wait for the chapter counter — proves the renderer parsed the file,
    // received a chapter count, and the view is mounted. Format: "1 / N".
    const counter = bookPage.locator('text=/^\\d+\\s*\\/\\s*\\d+$/').first()
    await counter.waitFor({ state: 'visible', timeout: 20000 })

    const counterText = (await counter.textContent())?.trim() ?? ''
    expect(counterText).toMatch(/^1\s*\/\s*\d+$/)

    // The total chapter count should be >= 1
    const total = Number(counterText.split('/')[1].trim())
    expect(total).toBeGreaterThanOrEqual(1)

    // An iframe carrying the chapter content should be present and visible
    const frame = bookPage.locator('iframe[title="AZW3 Render Test"]')
    await expect(frame).toBeVisible()
  } finally {
    await closeApp(launched)
  }
})
