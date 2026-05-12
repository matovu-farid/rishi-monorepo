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
 * Regression: the top toolbar (back, TOC, thumbnails, bookmark) used to scroll
 * away with the document. Root cause was `contain: strict` on the scroll
 * container — CSS containment makes the element a containing block for
 * `position: fixed` descendants, so the toolbar was anchored to the scroll
 * container's top edge rather than the viewport.
 *
 * The toolbar must stay pinned to the viewport top regardless of scrollTop.
 */
test('top toolbar stays pinned at viewport top after scrolling', async () => {
  const app: LaunchedApp = await launchApp()
  try {
    const book = await importBook(app.page, {
      fixturePath: PDF_FIXTURE,
      kind: 'pdf',
      title: 'Toolbar Persist Test'
    })

    await openBook(app.page, book.id)
    await app.page.waitForTimeout(3000)

    // Reveal toolbar by hovering near top
    await app.page.mouse.move(100, 10)
    await app.page.waitForTimeout(400)

    const toolbar = app.page.locator('[data-tour="reader-toolbar"]')
    const before = await toolbar.boundingBox()
    expect(before, 'toolbar mounted on initial open').not.toBeNull()
    expect(before!.y, 'toolbar pinned near viewport top on page 1').toBeGreaterThanOrEqual(0)
    expect(before!.y, 'toolbar pinned near viewport top on page 1').toBeLessThan(60)

    // Scroll deep into the document
    await app.page.evaluate(() => {
      const el = document.querySelector<HTMLElement>('div.overflow-y-scroll')
      if (!el) throw new Error('no scroll container')
      el.scrollTo({ top: 6000, behavior: 'auto' })
    })
    await app.page.waitForTimeout(600)

    // Re-hover to re-trigger toolbar visibility
    await app.page.mouse.move(100, 10)
    await app.page.waitForTimeout(400)

    const after = await toolbar.boundingBox()
    expect(after, 'toolbar still mounted after scroll').not.toBeNull()
    expect(after!.y, 'toolbar still on-screen after scroll').toBeGreaterThanOrEqual(0)
    expect(after!.y, 'toolbar still pinned at viewport top after scroll').toBeLessThan(60)
  } finally {
    await closeApp(app)
  }
})
