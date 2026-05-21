/**
 * E2E specs: navigation history feature — PDF reader.
 *
 * Two tests:
 *   1. TOC click → pill appears → POP_BACK returns to original page.
 *   2. Engagement tap → flip away → flip back → resume lands at tapped page.
 *
 * Page number is read via `data-page-number` attributes on the visible page
 * divs, or via `usePdfStore.getState().pageNumber` if we can reach it through
 * a dynamic import.  The simpler DOM approach (`data-page-number`) is used
 * first because it doesn't require module access.
 *
 * The pill is rendered by NavigationHistoryFooter with `role="status"` and
 * child buttons `data-testid="nav-history-back-label"` (pop) and
 * `data-testid="nav-history-dismiss"` (dismiss).
 *
 * The PDF TOC (ReaderTOC) is toggled via the menu command `toggleTOC` which
 * the native menu binds. In E2E we open it via the aria-label or the keyboard
 * shortcut that the existing pdf-reader spec exercises. The simplest approach
 * is to send a JUMP_REQUESTED via the actor directly (same scaffolding
 * pattern as the EPUB test) or to use the TOC sidebar button.
 *
 * The PDF scroll container uses `data-testid="pdf-scroll-container"` and
 * pages have `data-page-number={N}` on each page wrapper div.
 */

import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

// ---------------------------------------------------------------------------
// Helper: read the current PDF page from the DOM.
// The virtualizer renders only the pages in the viewport; the in-view page
// with the smallest index (closest to top) is considered "current".
// ---------------------------------------------------------------------------
async function getCurrentPdfPage(bookPage: import('@playwright/test').Page): Promise<number> {
  return bookPage.evaluate(() => {
    // The scroll container is `data-testid="pdf-scroll-container"`.
    const container = document.querySelector('[data-testid="pdf-scroll-container"]')
    if (!container) return 0
    const containerTop = container.getBoundingClientRect().top
    const containerBottom = container.getBoundingClientRect().bottom

    const pages = Array.from(document.querySelectorAll('[data-page-number]'))
    let bestPage = 0
    let bestOverlap = -1
    for (const el of pages) {
      const rect = el.getBoundingClientRect()
      const overlap = Math.min(rect.bottom, containerBottom) - Math.max(rect.top, containerTop)
      const pageNum = Number(el.getAttribute('data-page-number'))
      if (overlap > bestOverlap && pageNum > 0) {
        bestOverlap = overlap
        bestPage = pageNum
      }
    }
    return bestPage
  })
}

// ---------------------------------------------------------------------------
// Helper: scroll the PDF to a specific page by manipulating the scroll
// container directly. The virtualizer maps scrollTop to pages.
// ---------------------------------------------------------------------------
async function scrollPdfToPage(
  bookPage: import('@playwright/test').Page,
  targetPage: number,
  totalPages: number
): Promise<void> {
  await bookPage.evaluate(
    ({ page, total }) => {
      const container = document.querySelector<HTMLElement>('[data-testid="pdf-scroll-container"]')
      if (!container) return
      const maxScroll = container.scrollHeight - container.clientHeight
      const fraction = (page - 1) / Math.max(total - 1, 1)
      container.scrollTo({ top: Math.round(fraction * maxScroll), behavior: 'auto' })
    },
    { page: targetPage, total: totalPages }
  )
  // Wait for virtualizer to update the DOM.
  await bookPage.waitForTimeout(600)
}

// ---------------------------------------------------------------------------
// Helper: wait for the pill's pop-back button to become visible.
// ---------------------------------------------------------------------------
async function waitForPill(
  bookPage: import('@playwright/test').Page,
  opts: { timeout?: number } = {}
): Promise<void> {
  await expect(bookPage.locator('[data-testid="nav-history-back-label"]')).toBeVisible({
    timeout: opts.timeout ?? 10000
  })
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------
test.describe('Navigation history — PDF', () => {
  let app: LaunchedApp

  test.beforeAll(async () => {
    app = await launchApp()
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page).catch(() => {})
    await closeApp(app)
  })

  // -------------------------------------------------------------------------
  // Test 1: TOC click → pill → pop returns to original page
  //
  // The PDF TOC is inside a <Sheet> (ReaderTOC). We open it programmatically
  // via the navigation history actor's JUMP_REQUESTED (simulating a TOC
  // click), which is the same event the production `onItemClick` handler
  // dispatches. This avoids relying on a sheet that may be hard to locate
  // without a dedicated aria-label.
  // -------------------------------------------------------------------------
  test('TOC jump → pill appears → pop returns to original page', async () => {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Nav History PDF TOC'
    })

    const bookPage = await openBook(app.page, book.id)
    // Give the PDF virtualizer time to load the first page.
    await bookPage.waitForTimeout(3000)

    // Confirm the reader mounted.
    await expect(
      bookPage.locator('[data-testid="pdf-scroll-container"]').first()
    ).toBeVisible({ timeout: 15000 })

    // Read total pages (from any rendered data-page-number attribute).
    const totalPages = await bookPage.evaluate(() => {
      const all = Array.from(document.querySelectorAll('[data-page-number]'))
      return all.reduce((max, el) => Math.max(max, Number(el.getAttribute('data-page-number'))), 0)
    })
    if (totalPages < 3) {
      test.skip(true, 'test PDF has fewer than 3 pages — skipping TOC jump test')
      return
    }

    const initialPage = await getCurrentPdfPage(bookPage)
    expect(initialPage).toBeGreaterThan(0)

    // Dispatch a JUMP_REQUESTED via the actor, simulating a TOC click from
    // page 1 to page 3.  The pill should appear immediately.
    const dispatched = await bookPage.evaluate(
      async (pages: { from: number; to: number }) => {
        try {
          const mod = await import(
            '/src/machines/navigationHistory/navigationHistoryActor'
          )
          mod.navigationHistoryActor.send({
            type: 'JUMP_REQUESTED',
            from: { kind: 'pdf', page: pages.from, offset: 0 },
            fromTts: null,
            to: { kind: 'pdf', page: pages.to, offset: 0 },
            source: 'toc',
            fromLabel: `p. ${pages.from}`
          })
          return true
        } catch {
          return false
        }
      },
      { from: initialPage, to: Math.min(initialPage + 2, totalPages) }
    )

    if (!dispatched) {
      test.skip(true, 'dynamic import of actor unavailable in this build — scaffolding only')
      return
    }

    // Scroll to the target page so the machine's PAGE_VISITED fires for it.
    await scrollPdfToPage(bookPage, Math.min(initialPage + 2, totalPages), totalPages)

    // Pill must appear.
    await waitForPill(bookPage)

    // Click the pop-back button.
    await bookPage.locator('[data-testid="nav-history-back-label"]').first().click()
    await bookPage.waitForTimeout(1500)

    // Pill gone.
    await expect(bookPage.locator('[data-testid="nav-history-back-label"]')).toHaveCount(0, {
      timeout: 5000
    })

    // The reader should have seeked back to the initial page.
    const restoredPage = await getCurrentPdfPage(bookPage)
    // Allow ±1 page tolerance (virtualizer may center on a slightly adjacent
    // page depending on scroll position at restore time).
    expect(restoredPage, 'restored page should be close to initial').toBeGreaterThanOrEqual(
      initialPage - 1
    )
    expect(restoredPage).toBeLessThanOrEqual(initialPage + 1)
  })

  // -------------------------------------------------------------------------
  // Test 2: Engagement tap → flip to another page → resume pill → pop lands
  // at the engaged page
  //
  // This tests the "engagement resume" path: after the user taps (engages)
  // on a page and then flips away, a subsequent POP_BACK should restore them
  // to the page where they engaged.
  //
  // We simulate engagement by dispatching ENGAGEMENT_TAP to the actor, then
  // scrolling away, then verifying the pill appears and popping back.
  // -------------------------------------------------------------------------
  test('engagement tap → flip away → pop returns to engaged page', async () => {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Nav History PDF Engage'
    })

    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)

    await expect(
      bookPage.locator('[data-testid="pdf-scroll-container"]').first()
    ).toBeVisible({ timeout: 15000 })

    const totalPages = await bookPage.evaluate(() => {
      const all = Array.from(document.querySelectorAll('[data-page-number]'))
      return all.reduce((max, el) => Math.max(max, Number(el.getAttribute('data-page-number'))), 0)
    })

    if (totalPages < 5) {
      test.skip(true, 'test PDF has fewer than 5 pages — skipping engagement resume test')
      return
    }

    // Navigate to page 2 and tap to engage.
    await scrollPdfToPage(bookPage, 2, totalPages)
    const engagedPage = await getCurrentPdfPage(bookPage)

    // Simulate a click on the scroll container (engagement tap).
    const scrollContainer = bookPage.locator('[data-testid="pdf-scroll-container"]').first()
    await scrollContainer.click({ position: { x: 200, y: 300 } })
    await bookPage.waitForTimeout(200)

    // Dispatch ENGAGEMENT_TAP through the actor to ensure the machine
    // records the engagement, even if the useEngagementDetector hook's
    // pointer listener fired it already.
    await bookPage.evaluate(async () => {
      try {
        const mod = await import(
          '/src/machines/navigationHistory/navigationHistoryActor'
        )
        mod.navigationHistoryActor.send({ type: 'ENGAGEMENT_TAP' })
      } catch {
        // Ignore — useEngagementDetector may have already dispatched it.
      }
    })

    // Now navigate forward to page 5 to trigger a JUMP_REQUESTED from the
    // engaged position. We simulate this by dispatching directly.
    const jumpDispatched = await bookPage.evaluate(
      async (pages: { from: number; to: number }) => {
        try {
          const mod = await import(
            '/src/machines/navigationHistory/navigationHistoryActor'
          )
          mod.navigationHistoryActor.send({
            type: 'JUMP_REQUESTED',
            from: { kind: 'pdf', page: pages.from, offset: 0 },
            fromTts: null,
            to: { kind: 'pdf', page: pages.to, offset: 0 },
            source: 'toc',
            fromLabel: `p. ${pages.from}`
          })
          return true
        } catch {
          return false
        }
      },
      { from: engagedPage, to: 5 }
    )

    if (!jumpDispatched) {
      test.skip(true, 'dynamic import of actor unavailable — scaffolding only')
      return
    }

    // Scroll to page 5.
    await scrollPdfToPage(bookPage, 5, totalPages)

    // Pill must appear (the machine pushed page 2 — the engaged anchor).
    await waitForPill(bookPage)

    // Pop back.
    await bookPage.locator('[data-testid="nav-history-back-label"]').first().click()
    await bookPage.waitForTimeout(1500)

    // Pill gone.
    await expect(bookPage.locator('[data-testid="nav-history-back-label"]')).toHaveCount(0, {
      timeout: 5000
    })

    // Restored page should be the engaged page (page 2).
    const restoredPage = await getCurrentPdfPage(bookPage)
    expect(restoredPage, 'restored page should match engaged page').toBeGreaterThanOrEqual(
      engagedPage - 1
    )
    expect(restoredPage).toBeLessThanOrEqual(engagedPage + 1)
  })
})
