import { test, expect } from '@playwright/test'
import {
  AZW3_FIXTURE,
  closeApp,
  importBook,
  launchApp,
  openBook
} from './helpers/electron-app'

// Regression for the user-reported bug: AZW3 opens but the reader is
// visually blank even though foliate-js parses the file correctly.
// The previous version of this spec checked `body.textContent` which can
// return text from invisible nodes (display:none, off-screen, zero-size),
// so it passed while the page was visibly empty. This version verifies
// the iframe body is actually painted: real DOM dimensions, computed
// styles that allow visibility, and a non-white screenshot.
test('AZW3 reader paints the book content into the iframe', async () => {
  test.setTimeout(60000)
  const launched = await launchApp()
  const messages: string[] = []
  launched.app.on('window', (p) => {
    p.on('console', (m) => {
      const text = m.text()
      if (m.type() === 'error' || /Content Security Policy|azw3|parse|stylesheet|font/i.test(text)) {
        messages.push(`[${m.type()}] ${text}`)
      }
    })
    p.on('pageerror', (err) => messages.push(`[pageerror] ${err.message}`))
  })
  try {
    const book = await importBook(launched.page, {
      fixturePath: AZW3_FIXTURE,
      kind: 'azw3',
      title: 'AZW3 Visible'
    })
    const bookPage = await openBook(launched.page, book.id)

    const counter = bookPage.locator('[data-testid="azw3-page-counter"]')
    await counter.waitFor({ state: 'attached', timeout: 20000 })

    const iframe = bookPage.locator('iframe[title="AZW3 Visible"]')
    await expect(iframe).toBeVisible({ timeout: 10000 })

    // 1) The iframe element itself must have non-trivial layout dimensions.
    const iframeBox = await iframe.boundingBox()
    expect(iframeBox, 'iframe boundingBox()').not.toBeNull()
    expect(iframeBox!.width).toBeGreaterThan(200)
    expect(iframeBox!.height).toBeGreaterThan(200)

    // 2) Inside the iframe, the <body> must have laid-out children. We check
    //    the body's scrollHeight (DOM block-level height) — a blank document
    //    has scrollHeight === 0 or matches the empty viewport. A real book
    //    section has many hundreds of px of content.
    const frame = bookPage.frameLocator('iframe[title="AZW3 Visible"]')
    const body = frame.locator('body')
    try {
      await expect
        .poll(
          async () =>
            await body.evaluate((el) => {
              const html = el.ownerDocument.documentElement
              return Math.max(el.scrollHeight, html.scrollHeight)
            }),
          { timeout: 20000, intervals: [200, 500, 1000] }
        )
        .toBeGreaterThan(400)
    } catch (err) {
      const dump = await body
        .evaluate((el) => ({
          scrollHeight: el.scrollHeight,
          childCount: el.children.length,
          html: el.outerHTML.slice(0, 2000)
        }))
        .catch(() => ({ scrollHeight: -1, childCount: -1, html: '<no-body>' }))
      console.log('--- body dump ---\n' + JSON.stringify(dump, null, 2))
      console.log('--- console capture ---\n' + messages.join('\n'))
      throw err
    }

    // 3) Pixel-level visibility: screenshot the iframe region and make
    //    sure not every pixel is white. A completely white screenshot is
    //    proof the page is blank regardless of DOM contents.
    const png = await iframe.screenshot({ omitBackground: false, path: 'test-results/azw3-iframe.png' })
    const dataLen = png.length
    expect(dataLen).toBeGreaterThan(2000) // sanity

    // Decode a few sample pixels via Buffer indexing in the renderer to
    // check at least one non-white byte exists. PNG bytes after the
    // header include IDAT-compressed data — but we don't need decoding;
    // a screenshot of pure white compresses to a much smaller size than
    // one with content. We use the conservative size-vs-content check.
    // (Empirically, a 1200x800 PNG of solid white is < 5 KB; one with
    // glyphs or images is much larger.)
    expect(dataLen, 'iframe screenshot byte length').toBeGreaterThan(6000)

    // 4) The iframe sandbox must include both `allow-same-origin` AND
    //    `allow-scripts`. Real publisher AZW3s contain inline scripts and
    //    `<iframe srcdoc=...>` subframes; without `allow-scripts` the
    //    document layout never finishes and the page stays blank. Foliate's
    //    own paginator uses the same pair (see node_modules/foliate-js/
    //    paginator.js).
    const sandbox = await iframe.getAttribute('sandbox')
    expect(sandbox, 'iframe sandbox attribute').not.toBeNull()
    const tokens = (sandbox ?? '').split(/\s+/).filter(Boolean)
    expect(tokens).toContain('allow-same-origin')
    expect(tokens).toContain('allow-scripts')
  } finally {
    await closeApp(launched)
  }
})

// Regression for the user-reported bug: the fixture book shows 72 pages in
// GroupDocs but Rishi shows only "1 / 1" because foliate-js's KF8 splitter
// emits a single SKEL entry containing the whole book.
//
// Under the viewport-snapped column model, the whole chapter is loaded into
// the iframe and CSS columns split it into N viewport-wide pages — Next page
// simply scrolls `body.scrollLeft` forward by one viewport. data-total now
// reflects pages-within-current-chapter; for this 339KB single-section
// fixture that's many pages.
test('AZW3 reader paginates single-section books', async () => {
  test.setTimeout(60000)
  const launched = await launchApp()
  try {
    const book = await importBook(launched.page, {
      fixturePath: AZW3_FIXTURE,
      kind: 'azw3',
      title: 'AZW3 Pagination'
    })
    const bookPage = await openBook(launched.page, book.id)

    // Counter is now a subtle EPUB-style indicator with data attributes —
    // `data-current` / `data-total` expose values without needing visible
    // hover-state text. Fall back to data-testid lookup.
    const counter = bookPage.locator('[data-testid="azw3-page-counter"]')
    await counter.waitFor({ state: 'attached', timeout: 20000 })

    // Wait for the iframe to load + settle so the renderer has had a chance
    // to measure the column-paginated chapter and update data-total.
    const iframe = bookPage.locator('iframe[title="AZW3 Pagination"]')
    await expect(iframe).toBeVisible({ timeout: 10000 })
    const frame = bookPage.frameLocator('iframe[title="AZW3 Pagination"]')
    const body = frame.locator('body')
    await expect
      .poll(
        async () =>
          await body.evaluate((el) => (el.textContent ?? '').trim().length),
        { timeout: 20000, intervals: [200, 500, 1000] }
      )
      .toBeGreaterThan(50)

    // Wait for measurement to settle — data-total should be > 1 once the
    // column algorithm has laid out the chapter.
    await expect
      .poll(async () => Number(await counter.getAttribute('data-total')), {
        timeout: 20000,
        intervals: [200, 500, 1000]
      })
      .toBeGreaterThan(1)

    const current = Number(await counter.getAttribute('data-current'))

    // Click Next page — data-current must advance by 1 (scrollLeft jumps to
    // the next viewport-wide column page).
    await bookPage.locator('button[aria-label="Next page"]').click()
    await expect
      .poll(async () => Number(await counter.getAttribute('data-current')), {
        timeout: 10000,
        intervals: [200, 500]
      })
      .toBe(current + 1)
  } finally {
    await closeApp(launched)
  }
})
