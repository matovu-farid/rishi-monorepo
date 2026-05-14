import { test, expect } from '@playwright/test'
import {
  PDF_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

/**
 * Regression: scrolling UP across a page boundary used to cause a visible
 * jitter — the previous-page slot started at h-screen (loading state),
 * then shrank to the actual PDF dimensions when the page rendered. The
 * shrink shifted everything below it, the virtualizer applied a scroll
 * adjustment to keep visible content stable, and the user saw a brief
 * back-and-forth "snap".
 *
 * The fix makes the loading placeholder match the rendered page's
 * dimensions (no shrink → no shift → no jitter).
 *
 * Test: scroll down enough that pages above unmount (overscan only keeps
 * ~8 pages mounted). Then scroll back up by a small amount so the
 * previous page has to remount. Sample scrollTop at 16ms intervals
 * across the next ~600ms; assert no sample backtracks more than 80px
 * from the target scrollTop.
 */
test('scrolling up across a page boundary does not jitter', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Jitter Test'
    })

    const bookPage = await openBook(app.page, book.id)
    await bookPage.waitForTimeout(3000)

    // Scroll down well past the initial overscan window so pages above
    // get unmounted. Wait for renders / measurements to settle.
    await bookPage.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      el.scrollTo({ top: 14000, behavior: 'auto' })
    })
    await bookPage.waitForTimeout(2500)

    // Now scroll up by ~600px to cross at least one page boundary upward.
    // The page coming into view from above will need to mount + render.
    const samples = await bookPage.evaluate(async () => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      const target = el.scrollTop - 600
      el.scrollTo({ top: target, behavior: 'auto' })

      const out: number[] = []
      const start = performance.now()
      while (performance.now() - start < 600) {
        out.push(el.scrollTop)
        await new Promise((r) => {
          setTimeout(r, 16)
        })
      }
      return { target, samples: out }
    })

    // The user's intent was scrollTop = target. Allow slight settling
    // (virtualizer may end up slightly different due to measurement
    // adjustments), but no individual sample should be more than 80px
    // BELOW the final settled scrollTop — that would be the visible
    // back-jump we're guarding against.
    const settled = samples.samples[samples.samples.length - 1]
    const lowestSample = Math.min(...samples.samples)
    const backJump = settled - lowestSample
    expect(backJump, 'no scrollTop sample should snap back more than 80px').toBeLessThan(80)
  } finally {
    await closeApp(app)
  }
})
