import { test, expect } from '@playwright/test'
import { launchApp, closeApp, importBook, openBook, PDF_FIXTURE } from './helpers/electron-app'

test('reader has no in-window top toolbar after phase 2', async () => {
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })
    const bookPage = await openBook(launched.page, book.id)
    await bookPage.waitForTimeout(1500)
    const count = await bookPage.locator('[data-tour="reader-toolbar"]').count()
    expect(count).toBe(0)
  } finally {
    await closeApp(launched)
  }
})
