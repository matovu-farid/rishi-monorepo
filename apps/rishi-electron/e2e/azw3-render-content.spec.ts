import { test, expect } from '@playwright/test'
import {
  AZW3_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook
} from './helpers/electron-app'

// User-reported bug: opening an AZW3 shows the chapter counter ("1/1")
// but the iframe is blank — no book content renders. Root cause was the
// renderer's CSP blocking the `<link rel="stylesheet" href="blob:...">`
// references that foliate-js injects into each section's serialized HTML;
// the iframe loaded the document but its stylesheet load aborted, leaving
// the page visually empty.
//
// This spec is the regression assertion: real text from the parsed book
// must reach the rendered iframe body.
test('AZW3 reader renders book text into the iframe', async () => {
  test.setTimeout(60000)
  const launched = await launchApp()
  // Hook console on every new window so we can surface CSP / parser errors
  // if the assertion below fails.
  const messages: string[] = []
  launched.app.on('window', (p) => {
    p.on('console', (m) => {
      const text = m.text()
      if (m.type() === 'error' || /Content Security Policy|parse|azw3/.test(text)) {
        messages.push(`[${m.type()}] ${text}`)
      }
    })
    p.on('pageerror', (err) => messages.push(`[pageerror] ${err.message}`))
  })
  try {
    const book = await importBook(launched.page, {
      fixturePath: AZW3_FIXTURE,
      kind: 'azw3',
      title: 'AZW3 Content Test'
    })
    const bookPage = await openBook(launched.page, book.id)

    const counter = bookPage.locator('text=/^\\d+\\s*\\/\\s*\\d+$/').first()
    await counter.waitFor({ state: 'visible', timeout: 20000 })

    const frame = bookPage.frameLocator('iframe[title="AZW3 Content Test"]')
    const body = frame.locator('body')

    // The iframe must contain non-trivial text from the book. Poll because
    // the section loads asynchronously after mount (read file → parse →
    // serialize → blob URL → iframe navigation).
    try {
      await expect
        .poll(async () => (await body.textContent())?.trim().length ?? 0, {
          timeout: 20000,
          intervals: [200, 500, 1000]
        })
        .toBeGreaterThan(100)
    } catch (err) {
      console.log('--- renderer console ---\n' + messages.join('\n'))
      throw err
    }

    const text = (await body.textContent())?.trim() ?? ''
    expect(text.length, 'iframe body text length').toBeGreaterThan(100)
  } finally {
    await closeApp(launched)
  }
})
