import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  gotoLibrary,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Regression: reopening a recently-viewed PDF used to be a cold start —
 * react-pdf's <Document> destroyed its PDFDocumentProxy on every unmount,
 * so coming back from the library paid the full ~800ms parse again.
 *
 * The fix introduces a module-level LRU=3 cache in
 * services/reader-cache/pdf-cache that owns the proxy lifecycle, and
 * PdfView bypasses react-pdf's <Document> in favor of a DocumentContext
 * we mount ourselves (so AnnotationLayer can still resolve `pdf` +
 * `linkService`).
 *
 * Two ways this can break:
 *   1. AnnotationLayer's invariant fires after reopen → ErrorBoundary
 *      renders "Something went wrong" and tears the reader down.
 *   2. The proxy is reused from cache but the viewer never paints
 *      pages (e.g., context wiring regression).
 *
 * Asserts:
 *   - No ErrorBoundary fallback after reopen.
 *   - At least one rendered page canvas appears.
 */
test('reopening a PDF hits the warm-restore cache and renders pages', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Warm Restore Test'
    })

    await openBook(app.page, book.id)
    await app.page.waitForTimeout(3000)

    // First open should produce a rendered page canvas.
    const canvas = app.page.locator('canvas.react-pdf__Page__canvas').first()
    await expect(canvas, 'page canvas mounts on first open').toBeVisible({ timeout: 10000 })

    await gotoLibrary(app.page)
    await app.page.waitForTimeout(1000)

    await openBook(app.page, book.id)
    // Cache hit: pages should be on screen quickly, and crucially the
    // ErrorBoundary fallback must not appear.
    await app.page.waitForTimeout(2000)

    await expect(
      app.page.locator('text=Something went wrong'),
      'no ErrorBoundary fallback after reopen'
    ).toHaveCount(0)

    await expect(
      app.page.locator('canvas.react-pdf__Page__canvas').first(),
      'page canvas renders after reopen'
    ).toBeVisible({ timeout: 5000 })
  } finally {
    await closeApp(app)
  }
})
