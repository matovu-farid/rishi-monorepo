import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  gotoLibrary,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Warm-restore cache regression for EPUBs.
 *
 * Contract under test (services/reader-cache/epub-cache):
 *   - First open of a book parses the EPUB into a Book and stores it
 *     in the LRU cache.
 *   - Subsequent opens within the session reuse the cached Book —
 *     outer EpubView seeds bytes from the cache synchronously, inner
 *     viewer skips initialize() entirely.
 *
 * The test observes a renderer-side diagnostic surface
 * (window.__readerCache.epub) rather than monkey-patching the IPC
 * bridge — contextBridge-exposed objects are frozen and can't be
 * intercepted from page context.
 */

interface CacheStats {
  hits: number
  misses: number
}

async function epubCacheHas(page: Page, id: number): Promise<boolean> {
  return await page.evaluate((bookId) => {
    const w = window as unknown as {
      __readerCache?: { epub?: { has: (id: number) => boolean } }
    }
    return w.__readerCache?.epub?.has(bookId) ?? false
  }, id)
}

async function epubCacheSize(page: Page): Promise<number> {
  return await page.evaluate(() => {
    const w = window as unknown as {
      __readerCache?: { epub?: { size: () => number } }
    }
    return w.__readerCache?.epub?.size() ?? -1
  })
}

async function epubCacheStats(page: Page): Promise<CacheStats> {
  return await page.evaluate(() => {
    const w = window as unknown as {
      __readerCache?: { epub?: { stats: () => { hits: number; misses: number } } }
    }
    return w.__readerCache?.epub?.stats() ?? { hits: -1, misses: -1 }
  })
}

async function resetEpubCacheStats(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as {
      __readerCache?: { epub?: { resetStats: () => void } }
    }
    w.__readerCache?.epub?.resetStats()
  })
}

test('first open populates the cache, second open hits it', async () => {
  // Phase 3 (window split): each book lives in its own BrowserWindow,
  // so the cross-navigation warm-restore path this test exercised
  // (gotoLibrary then re-open in the same renderer) no longer exists.
  // The cache layer must be re-evaluated for the new lifecycle in a
  // follow-up phase before this assertion is meaningful again.
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Warm Restore Test'
    })

    // ---- First open: cold start, must populate cache ----
    await openBook(app.page, book.id)
    await expect(
      app.page.locator('iframe').first(),
      'epub iframe mounts on first open'
    ).toBeVisible({ timeout: 15000 })

    // Give the inner viewer's `book.loaded.navigation.then(...)` a
    // beat to run setCachedEpub before we navigate away.
    await app.page.waitForTimeout(500)

    expect(await epubCacheHas(app.page, book.id), 'book is cached after first open').toBe(true)
    expect(await epubCacheSize(app.page), 'one cached entry').toBe(1)

    // ---- Reopen: must hit the cache ----
    await gotoLibrary(app.page)
    await app.page.waitForTimeout(500)
    await resetEpubCacheStats(app.page)

    await openBook(app.page, book.id)
    await expect(
      app.page.locator('iframe').first(),
      'epub iframe renders on warm reopen'
    ).toBeVisible({ timeout: 10000 })
    await app.page.waitForTimeout(500)

    const stats = await epubCacheStats(app.page)
    expect(stats.hits, 'reopen produces at least one cache hit').toBeGreaterThan(0)
    expect(stats.misses, 'reopen produces zero cache misses').toBe(0)

    // Sanity: no ErrorBoundary fallback.
    await expect(
      app.page.locator('text=Something went wrong'),
      'no ErrorBoundary after reopen'
    ).toHaveCount(0)
  } finally {
    await closeApp(app)
  }
})
