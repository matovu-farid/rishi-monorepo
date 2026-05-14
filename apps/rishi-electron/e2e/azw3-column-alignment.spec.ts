import { test, expect } from '@playwright/test'
import { AZW3_FIXTURE, closeApp, importBook, launchApp, openBook } from './helpers/electron-app'

// Regression for an accumulating column-alignment drift: each page-turn
// should leave the leftmost column at exactly the same x-offset inside
// the iframe (= body's padding-left). The previous implementation advanced
// scrollLeft by `clientWidth + columnGap`, which over-shoots when body
// has horizontal padding; content drifts left by `2 * paddingX` per page.
test('AZW3 reader keeps the leftmost column aligned across pages', async () => {
  test.setTimeout(60000)
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: AZW3_FIXTURE,
      kind: 'azw3',
      title: 'AZW3 Alignment'
    })
    const bookPage = await openBook(launched.page, book.id)

    const counter = bookPage.locator('[data-testid="azw3-page-counter"]')
    await counter.waitFor({ state: 'attached', timeout: 20000 })

    const iframe = bookPage.locator('iframe[title="AZW3 Alignment"]')
    await expect(iframe).toBeVisible({ timeout: 10000 })

    // Helper: walk every text node inside paragraph-like elements and read
    // each text-line fragment's bounding rect via Range.getClientRects().
    // Unlike Element.getBoundingClientRect(), this returns one rect per
    // line/column fragment, so we don't accidentally pick up a paragraph
    // that visually starts on a later column but had a fragment outside
    // the viewport. We then find the smallest `.left` of fragments that
    // are inside the visible viewport — this is "where does the first
    // visible column actually start painting text".
    const measure = async () => {
      return await bookPage.evaluate(() => {
        const ifr = document.querySelector(
          'iframe[title="AZW3 Alignment"]'
        ) as HTMLIFrameElement | null
        if (!ifr?.contentWindow || !ifr.contentDocument?.body) return null
        const body = ifr.contentDocument.body
        const win = ifr.contentWindow
        const doc = ifr.contentDocument
        const cs = win.getComputedStyle(body)
        const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
        const viewportWidth = win.innerWidth
        const viewportHeight = win.innerHeight
        const nodes = body.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote')
        let minLeft = Number.POSITIVE_INFINITY
        const range = doc.createRange()
        for (const node of Array.from(nodes)) {
          // Per-line rectangles — handles paragraphs that span columns.
          range.selectNodeContents(node)
          const rects = range.getClientRects()
          for (const r of Array.from(rects)) {
            if (r.width === 0 || r.height === 0) continue
            // Must be inside the visible viewport (both axes).
            if (r.right <= 0 || r.left >= viewportWidth) continue
            if (r.bottom <= 0 || r.top >= viewportHeight) continue
            if (r.left < minLeft) minLeft = r.left
          }
        }
        return {
          paddingLeft,
          minLeft: Number.isFinite(minLeft) ? minLeft : null,
          viewportWidth,
          scrollLeft: body.scrollLeft
        }
      })
    }

    const total = Number(await counter.getAttribute('data-total'))
    // The fixture pages well over 5 pages; sample the first 5 with a hard
    // tolerance of 2px (well below paddingL of 2.25rem ≈ 36px so a drift
    // would jump out immediately).
    const samples = Math.min(5, total)
    const tolerance = 2

    await bookPage.waitForTimeout(300) // settle initial measurement
    const page0 = await measure()
    expect(page0, 'page 0 measurement').not.toBeNull()
    expect(page0!.minLeft, 'page 0 should find at least one visible paragraph').not.toBeNull()
    const expectedLeft = page0!.minLeft as number
    // data-current is now a global page number that starts at whatever
    // the initial measurement says, not a per-chapter "1". Use it as a
    // baseline and assert each click increments by exactly 1.
    const initialCurrent = Number(await counter.getAttribute('data-current'))

    for (let i = 1; i < samples; i++) {
      await bookPage.locator('button[aria-label="Next page"]').click()
      await expect
        .poll(async () => Number(await counter.getAttribute('data-current')), {
          timeout: 5000,
          intervals: [100, 250]
        })
        .toBe(initialCurrent + i)
      await bookPage.waitForTimeout(150) // let scroll settle
      const m = await measure()
      expect(m, `page ${i} measurement`).not.toBeNull()
      expect(m!.minLeft, `page ${i} minLeft should be defined`).not.toBeNull()
      expect(
        Math.abs((m!.minLeft as number) - expectedLeft),
        `page ${i + 1} leftmost-column drifted from ${expectedLeft}px to ${m!.minLeft}px`
      ).toBeLessThanOrEqual(tolerance)
    }
  } finally {
    await closeApp(launched)
  }
})
