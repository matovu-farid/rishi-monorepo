import { test, expect } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Regression: opening an EPUB cold-start used to stay on the inner
 * "Loading..." spinner forever. Cause: when the warm-restore cache
 * landed, the outer EpubView's epubData state was widened from
 * ArrayBuffer to Uint8Array (so it could be seeded from the cache
 * directly). The inner viewer's initialize() runtime check is
 * `instanceof ArrayBuffer` — Uint8Array fails that check (it's a view,
 * not the buffer), so the call fell into the no-data branch and
 * book.loaded.navigation never resolved.
 *
 * This spec exercises a fresh first-open and asserts:
 *   1. The rendered EPUB iframe appears within a tight window.
 *   2. The inner Loading… indicator is gone after content mounts.
 */
test('first open of an EPUB renders content (no infinite loader)', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'First Open Smoke Test'
    })

    await openBook(app.page, book.id)

    await expect(
      app.page.locator('iframe').first(),
      'epub iframe mounts on first open'
    ).toBeVisible({ timeout: 15000 })

    await expect(
      app.page.locator('text=Loading...'),
      'inner Loading… indicator clears once content is mounted'
    ).toHaveCount(0, { timeout: 5000 })
  } finally {
    await closeApp(app)
  }
})
