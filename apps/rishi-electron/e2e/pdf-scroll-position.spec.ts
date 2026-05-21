import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  getBookLocation,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Regression: page-only persistence snaps the user back to the top of the
 * page they were on, losing sub-page scroll position. A user scrolled to
 * the middle of page N expects to land at the middle of page N on reopen,
 * not at the start of page N.
 *
 * The saved location must encode both the page index AND the sub-page
 * scroll offset (in pixels), and restore both on reopen.
 */
test('PDF sub-page scroll position persists across close + reopen', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Scroll Position Persist Test'
    })

    let bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)

    // Scroll to a position that is intentionally MID-page, not at a page
    // boundary, so a page-only restore would visibly land elsewhere.
    const scrollTopBefore = await bookPage.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      el.scrollTo({ top: 6500, behavior: 'auto' })
      return el.scrollTop
    })
    expect(scrollTopBefore, 'scroll target should land near 6500').toBeGreaterThan(6000)

    // Wait for: scroll listener (80ms) + persist debounce (400ms) + IPC margin.
    await bookPage.waitForTimeout(1500)

    // The saved location must encode an offset, not just the page index.
    // Format is "page:offset" — old "5" alone means we lost sub-page state.
    const savedLocation = await getBookLocation(app.page, book.id)
    expect(savedLocation, 'location should encode page + sub-page offset').toMatch(/^\d+:\d+/)

    // Sanity: extracted offset is non-zero (we scrolled into the page).
    const savedOffset = Number(savedLocation?.split(':')[1] ?? 0)
    expect(savedOffset, 'sub-page offset should be > 0').toBeGreaterThan(0)

    // Round-trip: close the book window and reopen.
    await app.page.evaluate(async (id) => {
      const e = (window as unknown as { electron: { closeBook(id: number): Promise<void> } })
        .electron
      await e.closeBook(id)
    }, book.id)
    await app.page.waitForTimeout(1500)
    bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(4000)

    const scrollTopAfter = await bookPage.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      return el?.scrollTop ?? -1
    })

    // Tolerance: ±450px. The virtualizer's per-page measured heights vary
    // slightly between opens (different pages get measured first depending
    // on the initial scroll position), so the *absolute* scrollTop for the
    // same (page, sub-page offset) won't match exactly. The previous
    // page-only persistence would land us page-snapped to page top — for
    // an offset of ~1100px past page-start, that's an error >1100px. With
    // the sub-page offset persisted, the error drops to layout-shift slop.
    const tolerance = 450
    expect(scrollTopAfter, 'restored scrollTop should match before-close').toBeGreaterThan(
      scrollTopBefore - tolerance
    )
    expect(scrollTopAfter).toBeLessThan(scrollTopBefore + tolerance)

    // Page-index assertion: scrollTop alone could match within ±450px for the
    // wrong page (uniform-height fixture, off-by-one). Each rendered page
    // exposes `data-page-number` (pdf.tsx:877). The page whose top is at /
    // just above the viewport's scrollTop is the "displayed" one. Assert it
    // matches the saved page number from `savedLocation`.
    const savedPage = Number(savedLocation?.split(':')[0])
    const displayedPage = await bookPage.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!scroller) return -1
      const scrollerTop = scroller.getBoundingClientRect().top
      const targetY = scrollerTop + 1
      const nodes = Array.from(
        document.querySelectorAll<HTMLElement>('[data-page-number]')
      )
      let best: { num: number; dist: number } | null = null
      for (const node of nodes) {
        const rect = node.getBoundingClientRect()
        if (rect.bottom < scrollerTop) continue
        const dist = Math.abs(rect.top - targetY)
        const num = Number(node.getAttribute('data-page-number'))
        if (!Number.isFinite(num)) continue
        if (best === null || dist < best.dist) best = { num, dist }
      }
      return best?.num ?? -1
    })
    expect(displayedPage, 'displayed page should match saved page').toBe(savedPage)
  } finally {
    await closeApp(app)
  }
})
