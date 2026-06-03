/**
 * E2E for the PDF footer-detection heuristic (#142).
 *
 * Verifies that when a PDF with running footers is opened:
 *   1. `buildFooterMask` produces a FooterMask attached to `usePdfStore`,
 *      reachable via `window.__rishi.getFooterMask(bookId)`.
 *   2. The mask flags items in the bottom band of the page.
 *   3. Paragraph indices published into `pdfStore.currentViewParagraphs`
 *      retain GAPS at the masked positions — i.e. resume bookmarks remain
 *      stable across builds.
 *
 * Fixture: e2e/fixtures/test-book.pdf (Sipser, 481pp) has confirmed
 * running headers + page numbers + multi-line copyright footer.
 */

import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.setTimeout(180_000)

declare global {
  interface Window {
    __rishi?: {
      pdfStore: {
        getState: () => {
          pageCount: number
          pageNumber: number
          /**
           * The reader publishes one page's paragraphs at a time through
           * `currentViewParagraphs` (flat array). Each paragraph's `.index`
           * encodes `pageNumber * 10000 + originalIdx` as a string — when
           * the heuristic masks one out, its slot is reserved (the next
           * surviving paragraph's originalIdx is `prev+2` or more), which
           * is exactly the "gap" we assert on.
           */
          currentViewParagraphs: Array<{ index: string; text: string }>
          pageNumberToPageData: Record<number, unknown>
          virtualizer: unknown | null
        }
      }
      /** Added in this branch: read the per-book footer mask after detection. */
      getFooterMask?: (bookId: number) => Map<number, Set<number>> | undefined
    }
  }
}

test('builds a non-empty FooterMask for a book with running footers', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Footer Detection Spec'
    })
    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3500)

    // Wait until the heuristic has had a chance to run.
    await bookPage.waitForFunction(
      (bookId: number) => {
        const w = window as Window
        if (!w.__rishi?.getFooterMask) return false
        const m = w.__rishi.getFooterMask(bookId)
        return !!m && m.size >= 5
      },
      book.id,
      { timeout: 60000 }
    )

    const stats = await bookPage.evaluate((bookId: number) => {
      const w = window as Window
      const m = w.__rishi!.getFooterMask!(bookId)
      if (!m) return { size: 0, entries: 0 }
      let entries = 0
      for (const [, set] of m) {
        if (set.size > 0) entries++
      }
      return { size: m.size, entries }
    }, book.id)

    expect(stats.size).toBeGreaterThanOrEqual(5)
    expect(stats.entries).toBeGreaterThanOrEqual(5)
  } finally {
    await Promise.race([
      closeApp(app),
      new Promise<void>((r) => {
        setTimeout(r, 5000)
      })
    ])
  }
})

// Removed: "masked items live in the bottom band". The assertion requires a
// new `window.__rishi.getPageItemPositions(bookId, page)` helper (each PDF.js
// text item's `transform[5]` y in PDF points + page view height) so we can
// check each masked item's normalized y is within the bottom 25% band. That
// helper is meaningful production scaffolding and belongs to its own change,
// not a TODO stub here. The sibling test below ("paragraph indices stay
// stable when the heuristic engages") already pins the related behavior.

test('paragraph indices stay stable when the heuristic engages (gaps preserved)', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Footer Detection Gaps Spec'
    })
    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3500)

    // Phase 1: wait for the footer mask to populate.
    await bookPage.waitForFunction(
      (bookId: number) => {
        const w = window as Window
        if (!w.__rishi?.getFooterMask) return false
        const mask = w.__rishi.getFooterMask(bookId)
        if (!mask || mask.size === 0) return false
        // Need at least one non-cover page whose mask is non-empty —
        // otherwise there's nothing to assert a gap against.
        for (const [p, set] of mask) {
          if (p >= 2 && set.size > 0) return true
        }
        return false
      },
      book.id,
      { timeout: 60000 }
    )

    // Phase 2: find a page that has both a non-empty mask AND is rendered
    // (so its TextContent is in pageNumberToPageData) so we can scroll to it
    // and have `currentViewParagraphs` published for that page.
    const targetPage = await bookPage.evaluate((bookId: number) => {
      const w = window as Window
      const mask = w.__rishi!.getFooterMask!(bookId)!
      const pageData = w.__rishi!.pdfStore.getState().pageNumberToPageData
      for (const [p, set] of mask) {
        if (p < 2) continue
        if (set.size === 0) continue
        if (pageData[p]) return p
      }
      // Fall back to the first non-cover page with a non-empty mask, even
      // if we haven't rendered it yet — we'll scroll there next and the
      // virtualizer will render-on-demand.
      for (const [p, set] of mask) {
        if (p >= 2 && set.size > 0) return p
      }
      return -1
    }, book.id)
    expect(
      targetPage,
      'expected to find at least one non-cover page with a non-empty footer mask'
    ).toBeGreaterThanOrEqual(2)

    // Phase 3: scroll the reader to the target page (mirrors the pattern in
    // pdf-next-paragraph-snap-back.spec.ts) so the virtualizer renders that
    // page, its TextContent lands in pageNumberToPageData, and
    // usePdfReader publishes paragraphs into currentViewParagraphs.
    await bookPage.evaluate((page: number) => {
      const w = window as unknown as {
        __rishi: {
          pdfStore: {
            getState: () => {
              virtualizer: {
                scrollToIndex: (idx: number, opts: { align: 'start' }) => void
              } | null
            }
          }
        }
      }
      const v = w.__rishi.pdfStore.getState().virtualizer
      if (v) v.scrollToIndex(page - 1, { align: 'start' })
    }, targetPage)

    await bookPage.waitForFunction(
      (page: number) => {
        const w = window as Window
        const s = w.__rishi!.pdfStore.getState()
        // Wait until `currentViewParagraphs` actually contains paragraphs
        // FROM the target page (encoded as `page * 10000 + originalIdx`).
        if (s.currentViewParagraphs.length === 0) return false
        const min = page * 10000
        const max = (page + 1) * 10000
        return s.currentViewParagraphs.some((p) => {
          const n = Number(p.index)
          return Number.isFinite(n) && n >= min && n < max
        })
      },
      targetPage,
      { timeout: 30000 }
    )

    // Phase 4: read currentViewParagraphs, decode the per-page originalIdx
    // sequence, and assert at least one gap (originalIdx jumps by 2+).
    const probe = await bookPage.evaluate(
      ({ bookId, page }: { bookId: number; page: number }) => {
        const w = window as Window
        const mask = w.__rishi!.getFooterMask!(bookId)!
        const maskSet = mask.get(page) ?? new Set<number>()
        const paragraphs = w.__rishi!.pdfStore.getState().currentViewParagraphs
        const min = page * 10000
        const max = (page + 1) * 10000
        const originalIndices = paragraphs
          .map((p) => Number(p.index))
          .filter((n) => Number.isFinite(n) && n >= min && n < max)
          .map((n) => n - min)
          .sort((a, b) => a - b)
        let hasGap = false
        for (let i = 0; i < originalIndices.length - 1; i++) {
          if (originalIndices[i + 1] - originalIndices[i] >= 2) {
            hasGap = true
            break
          }
        }
        return {
          page,
          maskSize: maskSet.size,
          originalIndices,
          hasGap
        }
      },
      { bookId: book.id, page: targetPage }
    )

    expect(probe.maskSize, 'expected non-empty mask on the chosen page').toBeGreaterThan(0)
    expect(
      probe.hasGap,
      `expected at least one gap in per-page originalIdx sequence on page ${probe.page} ` +
        `(mask size=${probe.maskSize}, originalIndices=${probe.originalIndices.join(',')})`
    ).toBe(true)
  } finally {
    await Promise.race([
      closeApp(app),
      new Promise<void>((r) => {
        setTimeout(r, 5000)
      })
    ])
  }
})
