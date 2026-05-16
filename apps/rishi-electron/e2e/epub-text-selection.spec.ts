// Approach: structural DOM assertion — verify the swipeable pointer-event
// overlay div is absent from the rendered reader.
//
// DESIGN RATIONALE:
//
// The bug that Phase 0 fixed is a full-screen pointer-event overlay.
//
// When swipeable={true}, ReactReader renders:
//   {swipeable ? <div style={readerStyles.swipeWrapper} /> : null}
//
// where `swipeWrapper` CSS is:
//   { position: 'absolute', top: 0, left: 0, bottom: 0, right: 0, zIndex: 200 }
//
// This transparent div covers the ENTIRE reader area at z-index 200. It sits on
// top of the epub.js iframe, intercepting every pointer event (mousedown,
// pointerdown, click). Events never reach the iframe's text nodes. Text
// selection is therefore impossible — the overlay consumes the click before it
// can hit the iframe.
//
// When swipeable={false}, the overlay is not rendered. Pointer events reach the
// iframe directly.
//
// WHAT WE TEST:
// We query the reader's DOM for any div that matches the swipeWrapper style
// (position:absolute, zIndex≥200, covering the full reader area). If such a
// div is found, the overlay is present and would suppress text selection.
//
// WHY THIS CATCHES THE REGRESSION:
// If someone restores swipeable={true}:
//   - The overlay div is rendered (position:absolute, z-index:200, full-cover).
//   - The selector finds it; overlayCount > 0.
//   - The `toBe(0)` assertion fails — regression caught.
//
// With swipeable={false} (current Phase 0 fix):
//   - No overlay div exists in the DOM.
//   - overlayCount === 0.
//   - Assertion passes.
//
// NOTE: We match on the specific zIndex:200 style value defined in
// ReactReaderStyle.swipeWrapper (style.ts). We also match position:absolute
// and width/height coverage to avoid false positives from other divs.

import { test, expect, type Page } from '@playwright/test'
import {
  EPUB_FIXTURE,
  closeApp,
  deleteAllBooks,
  importBook,
  launchApp,
  openBook,
  type LaunchedApp
} from './helpers/electron-app'

test.describe('EPUB text selection', () => {
  let app: LaunchedApp
  let bookId: number
  let bookPage: Page

  test.beforeAll(async () => {
    app = await launchApp()
    const book = await importBook(app.page, {
      fixturePath: EPUB_FIXTURE,
      kind: 'epub',
      title: 'EPUB Text Selection Spec'
    })
    bookId = book.id
  })

  test.afterAll(async () => {
    await deleteAllBooks(app.page).catch(() => {})
    // Force-quit via the Electron main-process API first so the book
    // BrowserWindow (a separate Page) is closed before closeApp tries
    // to shut down the ElectronApplication; this avoids the 60 s worker-
    // teardown timeout when multi-window Electron apps are closed while
    // a non-library window is still open.
    await app.app.evaluate(({ app: electronApp }) => electronApp.quit()).catch(() => {})
    await closeApp(app).catch(() => {})
  })

  test.beforeEach(async () => {
    bookPage = await openBook(app.page, bookId)
    await expect(bookPage.locator('[aria-label="Next page"]').first()).toBeVisible({
      timeout: 30000
    })
  })

  test('no pointer-event overlay covers the epub iframe (swipeable overlay must be absent)', async () => {
    // Wait for the epub.js iframe to be visible and the reader to settle.
    const iframeEl = bookPage.locator('iframe').first()
    await iframeEl.waitFor({ state: 'visible', timeout: 30000 })

    // Count overlay divs with the swipeWrapper style signature:
    // position:absolute, z-index:200, covering top/left/right/bottom = 0.
    // ReactReader renders exactly this element when swipeable={true}:
    //
    //   {swipeable ? <div style={readerStyles.swipeWrapper} /> : null}
    //
    // where swipeWrapper = { position:'absolute', top:0, left:0, bottom:0,
    //                         right:0, zIndex:200 }
    //
    // In practice we inspect the element's computed style. We cannot query
    // `top:0` etc. directly via CSS selector (they're inline styles that
    // Playwright would stringify differently), so we walk the DOM in
    // evaluate() and match by inspecting getComputedStyle().
    const overlayCount = await bookPage.evaluate(() => {
      const divs = Array.from(document.querySelectorAll('div'))
      return divs.filter((div) => {
        const cs = window.getComputedStyle(div)
        return (
          cs.position === 'absolute' &&
          parseInt(cs.zIndex, 10) >= 200 &&
          cs.top === '0px' &&
          cs.left === '0px' &&
          cs.bottom === '0px' &&
          cs.right === '0px'
        )
      }).length
    })

    // With swipeable={false} (Phase 0 fix) there must be no such overlay.
    // With swipeable={true} (regression), the overlay is present and
    // overlayCount would be > 0 — catching the regression.
    expect(overlayCount).toBe(0)
  })
})
