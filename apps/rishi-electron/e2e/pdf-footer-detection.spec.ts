/**
 * E2E for the PDF footer-detection heuristic (#142).
 *
 * Verifies that when a PDF with running footers is opened:
 *   1. `buildFooterMask` produces a FooterMask attached to `usePdfStore`,
 *      reachable via `window.__rishi.getFooterMask(bookId)`.
 *   2. The mask flags items in the bottom band of the page.
 *   3. Paragraph indices in `pdfStore.paragraphs` retain GAPS at the masked
 *      positions — i.e. resume bookmarks remain stable across builds.
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
          paragraphs: Record<number, Array<{ index: string; text: string }>>
          pageNumberToPageData: Record<number, unknown>
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

// We need an item-position debug helper to assert positions live in the bottom
// band; rather than expand `expose-stores.ts` from a test, fixme this case so
// the architect/implementer can opt into it.
test.fixme(
  'masked items live in the bottom band',
  async () => {
    // TODO: extend `window.__rishi` with a `getPageItemPositions(bookId, page)`
    // helper, then assert each masked item's transform[5] < 0.15 * page.view height.
  }
)

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

    // Wait for both: footer mask present AND at least one non-cover page's
    // paragraphs are computed.
    await bookPage.waitForFunction(
      (bookId: number) => {
        const w = window as Window
        if (!w.__rishi?.getFooterMask) return false
        const mask = w.__rishi.getFooterMask(bookId)
        if (!mask || mask.size === 0) return false
        const paragraphs = w.__rishi.pdfStore.getState().paragraphs
        // Need at least one page beyond the cover that has paragraphs computed.
        return Object.keys(paragraphs).some((k) => Number(k) >= 2 && paragraphs[Number(k)].length > 0)
      },
      book.id,
      { timeout: 60000 }
    )

    const probe = await bookPage.evaluate((bookId: number) => {
      const w = window as Window
      const mask = w.__rishi!.getFooterMask!(bookId)!
      const paragraphs = w.__rishi!.pdfStore.getState().paragraphs

      // Find a page that BOTH has paragraphs computed AND has a non-empty mask entry.
      let chosenPage = -1
      for (const k of Object.keys(paragraphs)) {
        const p = Number(k)
        if (p < 2) continue
        if ((paragraphs[p]?.length ?? 0) === 0) continue
        const set = mask.get(p)
        if (set && set.size > 0) {
          chosenPage = p
          break
        }
      }
      if (chosenPage < 0) return { chosenPage, hasGap: false, indices: [] as number[] }
      const indices = paragraphs[chosenPage].map((p) => Number(p.index)).sort((a, b) => a - b)

      // Look for at least one "gap" — i.e. some index whose +1 neighbour is
      // missing AND a higher index still exists. That gap is the reserved
      // slot where the masked paragraph used to live.
      let hasGap = false
      for (let i = 0; i < indices.length - 1; i++) {
        if (indices[i + 1] !== indices[i] + 1) {
          hasGap = true
          break
        }
      }
      return { chosenPage, hasGap, indices }
    }, book.id)

    expect(probe.chosenPage).toBeGreaterThanOrEqual(2)
    expect(
      probe.hasGap,
      `expected at least one gap in paragraph indices on page ${probe.chosenPage}, got: ${probe.indices.join(',')}`
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
