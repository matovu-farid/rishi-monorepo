import { test, expect } from '@playwright/test'
import { MOBI_FIXTURE, closeApp, importBook, launchApp, openBook } from './helpers/electron-app'

// Regression: the bottom page counter must reflect a global "page X of book"
// number, not the per-chapter page index. The previous implementation surfaced
// `pageWithinChapter + 1`, which resets to 1 every time the reader crosses
// into a new chapter — so after page-turning past the end of chapter N, the
// counter would go back to "1" instead of advancing to "N+1".
//
// Test strategy mirrors how a reader would notice this: open the book, hold
// a personal "page count" that starts at whatever the reader shows initially,
// click Next, expect the displayed number to be exactly one larger every
// time — including across chapter boundaries.
test('MOBI page counter advances globally across chapter boundaries', async () => {
  test.setTimeout(90000)
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: MOBI_FIXTURE,
      kind: 'mobi',
      title: 'MOBI Global Counter'
    })
    const bookPage = await openBook(launched.page, book.id)

    const counter = bookPage.locator('[data-testid="azw3-page-counter"]')
    await counter.waitFor({ state: 'attached', timeout: 20000 })

    const iframe = bookPage.locator('iframe[title="MOBI Global Counter"]')
    await expect(iframe).toBeVisible({ timeout: 10000 })

    // Settle initial measurement.
    await bookPage.waitForTimeout(500)

    const nextBtn = bookPage.locator('button[aria-label="Next page"]')
    let prev = Number(await counter.getAttribute('data-current'))
    expect(Number.isFinite(prev) && prev >= 1, `initial counter should be ≥ 1, got ${prev}`).toBe(
      true
    )

    // Track chapter changes through the iframe `src` (one blob URL per
    // chapter). Once we've crossed at least one boundary AND validated a few
    // pages past the boundary, we've exercised the bug case.
    let lastSrc = await iframe.getAttribute('src')
    let chapterCrossings = 0
    let postCrossingClicks = 0
    const POST_CROSSING_MIN = 3

    // Books may have many pages per chapter; cap clicks so a small fixture
    // doesn't loop forever. The MOBI fixture's first body chapter has more
    // than 5 pages (see azw3-column-alignment.spec.ts) so 80 clicks should
    // reliably cross at least one boundary.
    const MAX_CLICKS = 80
    for (let i = 0; i < MAX_CLICKS; i++) {
      const nextVisible = await nextBtn.isVisible().catch(() => false)
      if (!nextVisible) break

      await nextBtn.click()

      // Poll until the counter advances. If it never reaches prev + 1, the
      // bug just hit — fail the test with both the expected and observed
      // values so a regression is obvious in CI output.
      await expect
        .poll(async () => Number(await counter.getAttribute('data-current')), {
          timeout: 5000,
          intervals: [100, 250],
          message: `after click ${i + 1}, counter should have advanced to ${prev + 1}`
        })
        .toBe(prev + 1)

      prev = prev + 1

      const currSrc = await iframe.getAttribute('src')
      if (currSrc !== lastSrc) {
        chapterCrossings += 1
        lastSrc = currSrc
      }
      if (chapterCrossings >= 1) postCrossingClicks += 1
      if (postCrossingClicks >= POST_CROSSING_MIN) break
    }

    expect(
      chapterCrossings,
      'test fixture must page through at least one chapter boundary to exercise the bug'
    ).toBeGreaterThanOrEqual(1)
  } finally {
    await closeApp(launched)
  }
})
