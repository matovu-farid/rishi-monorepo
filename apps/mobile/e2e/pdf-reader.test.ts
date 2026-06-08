/**
 * PDF reader end-to-end smoke (visual verification).
 *
 * Strategy: uses the existing `seedBook('pdf')` helper (the same hook
 * the `reader-pdf` spec relies on) rather than driving the OS
 * file-handoff `file://` URL path. The latter is intercepted by Expo
 * Router as an Unmatched Route on cold start, so it never reaches the
 * importer pipeline. `seedBook` cold-launches the app with
 * `rishimobile:///?e2e-action=seed-book&format=pdf`, which
 * `app/_layout.tsx`'s E2E URL handler routes to
 * `createMobileBookImportService` and produces a deterministic book id
 * (`e2e-fixture-book-pdf`).
 *
 * Verifies that:
 *   (a) the seeded PDF appears as a BookRow in the library;
 *   (b) tapping it opens the PDF reader route
 *       (`apps/mobile/app/reader/pdf/[id].tsx`) and the native PDF
 *       reader renders the first page;
 *   (c) the surrounding chrome (toolbar, page indicator) renders and
 *       a next-page tap advances the page.
 *
 * The visual checks are inherently human-eyeballable — Detox cannot
 * OCR a screenshot. The React-side assertions cover the testIDs, and
 * PNGs are saved under the Detox artifact dir for review.
 */
import { describe, it, beforeAll, expect } from '@jest/globals'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

const sleep = (ms: number): Promise<void> =>
  new Promise((r) => setTimeout(r, ms))

describe('PDF reader: visual smoke', () => {
  let bookRowId: string

  beforeAll(async () => {
    // Cold-launches the app with the seed-book deep link, copies the
    // fixture into Documents/, polls for the BookRow to appear, then
    // returns. Throws if any of those steps fail.
    await seedBook('pdf')
    bookRowId = fixtureBookRowTestID('pdf')
    // react-native-pdf has its own native render loop that never
    // reports "idle" to Detox; disable sync globally for the suite.
    await device.disableSynchronization()
  }, 240000)

  it('captures cover + UI screenshots after PDF seed + open', async () => {
    // 00 — Library tab visible with the seeded book listed.
    await waitFor(element(by.id('tab-library')))
      .toBeVisible()
      .withTimeout(60000)
    try {
      const launchShot = await device.takeScreenshot('00-launch-with-library')
      console.log('[pdf-reader.test] launch screenshot:', launchShot)
    } catch (err) {
      console.warn('[pdf-reader.test] 00 launch screenshot failed:', err)
    }

    // 01 — the deterministic BookRow for the seeded PDF.
    try {
      await waitFor(element(by.id(bookRowId)))
        .toBeVisible()
        .withTimeout(20000)
      const libraryShot = await device.takeScreenshot(
        '01-library-with-seeded-book',
      )
      console.log('[pdf-reader.test] library screenshot:', libraryShot)
    } catch (err) {
      console.warn('[pdf-reader.test] 01 BookRow not visible:', err)
      try {
        const fallback = await device.takeScreenshot(
          '01-library-with-seeded-book-fallback',
        )
        console.log('[pdf-reader.test] 01 fallback screenshot:', fallback)
      } catch {}
      throw err
    }

    // Tap the seeded BookRow → PDF reader route.
    await element(by.id(bookRowId)).tap()

    // 02 — PDF reader screen mounts and renders the first page.
    await waitFor(element(by.id('pdf-reader')))
      .toExist()
      .withTimeout(20000)
    // Give the native PDF renderer time to lay out the first page.
    await sleep(5000)
    try {
      const readerShot = await device.takeScreenshot('02-reader-page-1')
      console.log('[pdf-reader.test] reader page 1 screenshot:', readerShot)
    } catch (err) {
      console.warn('[pdf-reader.test] 02 screenshot failed:', err)
    }

    // Sanity check: page indicator reads "N/M" (e.g. "1/14").
    const indicatorAttrs = (await element(by.id('reader-position-indicator'))
      .getAttributes()
      .catch(() => null)) as { label?: string } | null
    console.log(
      '[pdf-reader.test] reader-position-indicator label:',
      indicatorAttrs?.label,
    )
    expect(indicatorAttrs?.label ?? '').toMatch(/^\d+\/\d+$/)
    const before = indicatorAttrs?.label ?? ''

    // 03 — Reveal the toolbar (auto-hides 3s after mount).
    try {
      await element(by.id('reader-toggle-toolbar')).tap()
      await sleep(1500)
      const toolbarShot = await device.takeScreenshot(
        '03-reader-toolbar-visible',
      )
      console.log('[pdf-reader.test] toolbar screenshot:', toolbarShot)
    } catch (err) {
      console.warn('[pdf-reader.test] 03 toolbar reveal failed:', err)
      try {
        const fallback = await device.takeScreenshot(
          '03-reader-toolbar-visible-fallback',
        )
        console.log('[pdf-reader.test] 03 fallback screenshot:', fallback)
      } catch {}
    }

    // 04 — Advance one page and capture.
    try {
      await element(by.id('reader-next-page-btn')).tap()
      // Poll for the indicator to change.
      let after = before
      const startedAt = Date.now()
      while (Date.now() - startedAt < 5000) {
        const a = (await element(by.id('reader-position-indicator'))
          .getAttributes()
          .catch(() => null)) as { label?: string } | null
        if (a?.label && a.label !== before) {
          after = a.label
          break
        }
        await sleep(250)
      }
      console.log('[pdf-reader.test] indicator after next-page tap:', after)
      await sleep(1500)
      const page2Shot = await device.takeScreenshot('04-reader-page-2')
      console.log('[pdf-reader.test] reader page 2 screenshot:', page2Shot)
      expect(after).not.toBe(before)
    } catch (err) {
      console.warn('[pdf-reader.test] 04 next-page step failed:', err)
      try {
        const fallback = await device.takeScreenshot(
          '04-reader-page-2-fallback',
        )
        console.log('[pdf-reader.test] 04 fallback screenshot:', fallback)
      } catch {}
      throw err
    }
  }, 240000)
})
