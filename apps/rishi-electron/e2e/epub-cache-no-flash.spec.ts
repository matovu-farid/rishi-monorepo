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
 * Regression: reopening a book that already has a window must NOT remount
 * the inner EPUB viewer, and must NOT flash the inner `<Loader />`
 * ("Loading..."). The loader flash was originally a microtask-gap bug in
 * the inner viewer constructor; this spec was added to keep that surface
 * stable. Even after the per-window split (PR #253) the same surface
 * matters: if `openBook` ever stops returning the existing window and
 * instead recreates one, the loader flash returns.
 *
 * Phase 3 contract reframing: the original spec exercised gotoLibrary →
 * reopen-in-same-renderer, which no longer exists. The new test instead
 * pins the focus-existing-window invariant directly:
 *   1. Open a book; wait for the iframe so the inner viewer is mounted.
 *   2. Install a high-frequency loader poller in the book window.
 *   3. Call `openBook` again for the same id and confirm the SAME Page
 *      object came back (the WindowManager focus-existing path).
 *   4. Assert the loader poller never observed a visible "Loading..."
 *      paragraph after step 2 — i.e. no remount/flash.
 */
test('reopening an already-open book does not remount or flash the inner loading view', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'No-Flash Test'
    })

    // ---- Cold first open: wait until the inner viewer is fully mounted ----
    const bookPage = await openBook(app.page, book.id)
    await expect(bookPage.locator('iframe').first()).toBeVisible({ timeout: 15000 })

    // setCachedEpub runs after `book.loaded.navigation` resolves; wait for it
    // so the post-mount state is fully settled before installing the poller.
    await expect
      .poll(
        async () =>
          await bookPage.evaluate((id) => {
            const w = window as unknown as {
              __readerCache?: { epub?: { has: (id: number) => boolean } }
            }
            return w.__readerCache?.epub?.has(id) ?? false
          }, book.id),
        { timeout: 10000 }
      )
      .toBe(true)

    // ---- Install a high-frequency VISIBLE-loader poller ----
    // The hidden paragraph reader (positioned off-screen with opacity:0)
    // mounts its own ReactReader without the cache, so its loadingView
    // appears in the DOM. We only care about loaders that are actually
    // visible to the user — check viewport-intersection + computed
    // opacity/display/visibility up the ancestor chain.
    await bookPage.evaluate(() => {
      const w = window as unknown as {
        __loaderEverSeen?: boolean
        __loaderPollHandle?: number
      }
      w.__loaderEverSeen = false

      const visibleToUser = (el: Element): boolean => {
        const rect = el.getBoundingClientRect()
        if (rect.width === 0 || rect.height === 0) return false
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

    // ---- Reopen the same book: must reuse the existing window (no remount) ----
    const reopened = await openBook(app.page, book.id)
    expect(
      reopened,
      'openBook reuses the existing book window instead of spawning a new one'
    ).toBe(bookPage)
    // Drain a few extra frames so any late loader render is caught.
    await bookPage.waitForTimeout(500)

    const seen = await bookPage.evaluate(() => {
      const w = window as unknown as {
        __loaderEverSeen?: boolean
        __loaderPollHandle?: number
      }
      if (w.__loaderPollHandle !== undefined) cancelAnimationFrame(w.__loaderPollHandle)
      return w.__loaderEverSeen === true
    })

    expect(seen, 'reopen must not render the inner loading view at any frame').toBe(false)
  } finally {
    await closeApp(app)
  }
})
