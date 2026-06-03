import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Warm-restore cache regression for EPUBs.
 *
 * Contract under test (services/reader-cache/epub-cache):
 *   - First open of a book parses the EPUB into a Book and stores it in
 *     the LRU cache.
 *   - The cache exposes a diagnostic surface on window.__readerCache.epub
 *     (has/size/stats/resetStats). This pin matters because peer specs
 *     read it.
 *   - Reopening a book that already has a window focuses that existing
 *     window (windowManager.openBook reuses entries); the renderer is
 *     not torn down so the cache survives the reopen.
 *
 * Phase 3 note: PR #253 split each book into its own BrowserWindow. The
 * original cross-navigation warm-restore path (gotoLibrary then re-mount
 * the reader in the same window) no longer exists, so a "second open
 * produces hits>0" assertion is not e2e-observable — there is no
 * remount of EpubView within the book window's lifetime in production.
 * This spec now pins what *is* observable: cache population on first
 * open, and the focus-existing-window invariant on reopen.
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

test('first open populates the cache; reopen reuses the existing window', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'Warm Restore Test'
    })

    // ---- First open: cold start, must populate cache ----
    const bookPage = await openBook(app.page, book.id)
    await expect(
      bookPage.locator('iframe').first(),
      'epub iframe mounts on first open'
    ).toBeVisible({ timeout: 15000 })

    // setCachedEpub runs inside book.loaded.navigation.then(...) — give that
    // microtask a beat to land before polling. Poll rather than fixed wait
    // so a fast machine doesn't waste time and a slow one still passes.
    await expect
      .poll(async () => await epubCacheHas(bookPage, book.id), { timeout: 10000 })
      .toBe(true)
    expect(await epubCacheSize(bookPage), 'exactly one cached entry').toBe(1)

    const statsAfterFirstOpen = await epubCacheStats(bookPage)
    expect(statsAfterFirstOpen.misses, 'first open is a cache miss').toBeGreaterThan(0)

    // ---- Reopen: openBook reuses the existing window (focus-existing
    //      path in WindowManager). No remount → cache survives.
    const reopened = await openBook(app.page, book.id)
    expect(
      reopened,
      'openBook reuses the existing book window instead of spawning a new one'
    ).toBe(bookPage)
    expect(await epubCacheHas(bookPage, book.id), 'cache survives reopen').toBe(true)
    expect(await epubCacheSize(bookPage), 'cache size unchanged after reopen').toBe(1)

    // Sanity: no ErrorBoundary fallback.
    await expect(
      bookPage.locator('text=Something went wrong'),
      'no ErrorBoundary after reopen'
    ).toHaveCount(0)
  } finally {
    await closeApp(app)
  }
})
