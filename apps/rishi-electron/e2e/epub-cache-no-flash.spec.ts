import { test, expect } from '@playwright/test'
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
 * Regression: reopening a cached EPUB still briefly flashed the inner
 * viewer's `loadingView` (the <Loader /> with "Loading..." text and a
 * spinner). The cache was being hit, but the inner EpubView class
 * component initialized with `isLoaded: false` — so the first render
 * showed the loading view, then componentDidMount → initBook scheduled
 * `book.loaded.navigation.then(...)` whose microtask later flipped
 * isLoaded to true. That microtask gap is visible.
 *
 * On cache hit, the Book is already loaded — there's no async work to
 * wait for. The fix is to detect the cache hit in the constructor and
 * seed `isLoaded: true` from the start, eliminating the flash.
 *
 * This spec polls the DOM at high frequency during a warm-restore
 * reopen and asserts the "Loading..." text never appears.
 */
test.skip('warm-restore reopen does not flash the inner loading view', async () => {
  // Phase 3 (window split) replaced in-window navigation with one
  // BrowserWindow per book. The original cache-warm-restore code path
  // (gotoLibrary then re-mount the reader in the same window) no longer
  // exists — instead, closing the book window destroys its renderer
  // entirely. Skipping until the cache layer is reworked around the
  // new BrowserWindow lifecycle.
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'No-Flash Test'
    })

    // ---- Cold first open: warm the cache ----
    await openBook(app.page, book.id)
    await expect(app.page.locator('iframe').first()).toBeVisible({ timeout: 15000 })
    await app.page.waitForTimeout(500)

    const isCached = await app.page.evaluate((id) => {
      const w = window as unknown as {
        __readerCache?: { epub?: { has: (id: number) => boolean } }
      }
      return w.__readerCache?.epub?.has(id) ?? false
    }, book.id)
    expect(isCached, 'cache populated after first open').toBe(true)

    // ---- Back to library ----
    await gotoLibrary(app.page)
    // Wait for the library to settle so its own loaders aren't in flight.
    await app.page.waitForTimeout(800)

    // ---- Install a high-frequency VISIBLE-loader poller, then reopen ----
    // The hidden paragraph reader (positioned off-screen with opacity:0)
    // mounts its own ReactReader without the cache, so its loadingView
    // appears in the DOM. We only care about loaders that are actually
    // visible to the user — check viewport-intersection + computed
    // opacity/display/visibility up the ancestor chain.
    await app.page.evaluate(() => {
      const w = window as unknown as {
        __loaderEverSeen?: boolean
        __loaderPollHandle?: number
      }
      w.__loaderEverSeen = false

      const visibleToUser = (el: Element): boolean => {
        const rect = el.getBoundingClientRect()
        if (rect.width === 0 || rect.height === 0) return false
        // Allow a small margin so partially-onscreen elements still count.
        if (
          rect.right < 0 ||
          rect.bottom < 0 ||
          rect.left > window.innerWidth ||
          rect.top > window.innerHeight
        ) {
          return false
        }
        let node: Element | null = el
        while (node) {
          const s = window.getComputedStyle(node)
          if (s.display === 'none' || s.visibility === 'hidden') return false
          if (parseFloat(s.opacity) === 0) return false
          node = node.parentElement
        }
        return true
      }

      const tick = (): void => {
        const candidates = document.querySelectorAll('p')
        for (const c of candidates) {
          if (c.textContent === 'Loading...' && visibleToUser(c)) {
            w.__loaderEverSeen = true
            break
          }
        }
        w.__loaderPollHandle = requestAnimationFrame(tick)
      }
      w.__loaderPollHandle = requestAnimationFrame(tick)
    })

    await openBook(app.page, book.id)
    await app.page.locator('iframe').first().waitFor({ state: 'visible', timeout: 10000 })
    // Drain a few extra frames so any late loader render is caught.
    await app.page.waitForTimeout(300)

    const seen = await app.page.evaluate(() => {
      const w = window as unknown as {
        __loaderEverSeen?: boolean
        __loaderPollHandle?: number
      }
      if (w.__loaderPollHandle !== undefined) cancelAnimationFrame(w.__loaderPollHandle)
      return w.__loaderEverSeen === true
    })

    expect(seen, 'warm-restore reopen must not render the inner loading view at any frame').toBe(
      false
    )
  } finally {
    await closeApp(app)
  }
})
