import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Regression: the first open of a PDF must populate the warm-restore cache
 * (services/reader-cache/pdf-cache) and render at least one page.
 *
 * Why this matters:
 *   - PdfView bypasses react-pdf's <Document> and owns the PDFDocumentProxy
 *     lifecycle via the cache. If the cache wiring breaks, setCachedPdf
 *     never runs and any in-renderer remount of PdfView would pay the
 *     ~800ms parse again (and AnnotationLayer can blow up if `pdf`
 *     resolves before `linkService`).
 *   - The cache also exposes a diagnostic surface on window.__readerCache.pdf
 *     used by other regression specs; this test pins that surface exists
 *     and is reachable from the book-window renderer.
 *
 * Phase 3 note: PR #253 split each book into its own BrowserWindow, so the
 * old "open → gotoLibrary → reopen in the same renderer" warm-restore path
 * no longer exists. Reopening a book that already has a window simply
 * focuses that existing window (windowManager.openBook reuses the entry)
 * with no remount, so a "second open is faster" assertion is not e2e-
 * observable. This spec was rewritten to pin the still-meaningful invariants:
 *   1. First open renders a page canvas.
 *   2. First open populates the cache (size 1, has(bookId) true).
 *   3. No ErrorBoundary fallback.
 *   4. Reopening from the library returns the SAME book window and
 *      preserves the cache (no destructive remount).
 */
test('first open of a PDF renders pages and populates the warm-restore cache', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Warm Restore Test'
    })

    const bookPage = await openBook(app.page, book.id)

    // 1. First open: page canvas mounts.
    const canvas = bookPage.locator('canvas.react-pdf__Page__canvas').first()
    await expect(canvas, 'page canvas mounts on first open').toBeVisible({ timeout: 15000 })

    // 2. ErrorBoundary did not fire.
    await expect(
      bookPage.locator('text=Something went wrong'),
      'no ErrorBoundary fallback on first open'
    ).toHaveCount(0)

    // 3. Cache is populated. Polled because setCachedPdf runs after the
    //    initial canvas paint (the proxy promise resolves and then we set).
    await expect
      .poll(
        async () =>
          await bookPage.evaluate((id) => {
            const w = window as unknown as {
              __readerCache?: { pdf?: { has: (id: number) => boolean; size: () => number } }
            }
            return {
              has: w.__readerCache?.pdf?.has(id) ?? false,
              size: w.__readerCache?.pdf?.size() ?? -1
            }
          }, book.id),
        { timeout: 10000 }
      )
      .toEqual({ has: true, size: 1 })

    // 4. Reopen from library returns the SAME window (windowManager focus-
    //    existing path) — no remount, cache survives, no ErrorBoundary.
    const reopened = await openBook(app.page, book.id)
    expect(
      reopened,
      'openBook reuses the existing book window instead of spawning a new one'
    ).toBe(bookPage)
    await expect(
      bookPage.locator('text=Something went wrong'),
      'no ErrorBoundary fallback after reopen'
    ).toHaveCount(0)
    expect(
      await bookPage.evaluate((id) => {
        const w = window as unknown as {
          __readerCache?: { pdf?: { has: (id: number) => boolean } }
        }
        return w.__readerCache?.pdf?.has(id) ?? false
      }, book.id),
      'cache still populated after reopen'
    ).toBe(true)
  } finally {
    await closeApp(app)
  }
})
