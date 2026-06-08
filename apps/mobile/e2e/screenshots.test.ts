/**
 * Screenshot-driven smoke walk for rishi-mobile.
 *
 * Goal: capture PNGs of each key app stage so a human can eyeball the UI
 * without booting a simulator. Resilient by design — each step is in its
 * own try/catch so one failure doesn't kill the rest. Use
 *   detox test --configuration ios.sim.debug --take-screenshots all
 * to persist the artifacts to `artifacts/<config>.<timestamp>/`.
 *
 * Detox globals (`device`, `element`, `by`, `waitFor`) are injected by
 * the jest environment in `e2e/jest.config.js`.
 */
import { describe, it } from '@jest/globals'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

describe('screenshots: key app stages', () => {
  it('captures launch, library, import, reader, and a swiped page', async () => {
    // -----------------------------------------------------------------
    // 01 - launch
    // The `beforeAll` in e2e/setup.ts has already cold-launched the app
    // (newInstance=true). Grab a screenshot as soon as the runner gives
    // us control.
    try {
      await device.takeScreenshot('01-launch')
    } catch (err) {
      console.warn('01-launch screenshot failed:', err)
    }

    // -----------------------------------------------------------------
    // 02 - library (empty state, since we haven't seeded yet)
    try {
      await waitFor(element(by.id('tab-library')))
        .toBeVisible()
        .withTimeout(60000)
      // Give the empty-state container a beat to settle / animate in.
      await sleep(500)
      await device.takeScreenshot('02-library')
    } catch (err) {
      console.warn('02-library screenshot failed:', err)
    }

    // -----------------------------------------------------------------
    // 03 - import sheet (best-effort)
    // The empty-state has a "library-empty-import-btn" that fires a
    // native UIDocumentPickerView which Detox can't actually drive. We
    // still tap it so the screenshot shows whatever modal/alert the app
    // renders mid-pick. If the button isn't there, screenshot whatever
    // is on screen.
    try {
      const importBtn = element(by.id('library-empty-import-btn'))
      await importBtn.tap()
      await sleep(1500)
      await device.takeScreenshot('03-import-sheet')
    } catch (err) {
      console.warn('03-import-sheet screenshot failed:', err)
      // Best-effort fallback so the artifact still exists.
      try {
        await device.takeScreenshot('03-import-sheet-fallback')
      } catch {}
    }

    // -----------------------------------------------------------------
    // Seed a PDF so the reader has something to open.
    // seedBook() cold-launches the app via deep link, so any picker/alert
    // from step 03 is dismissed by the relaunch.
    let bookRowId: string | null = null
    try {
      await seedBook('pdf')
      bookRowId = fixtureBookRowTestID('pdf')
    } catch (err) {
      console.warn('seedBook(pdf) failed:', err)
    }

    // -----------------------------------------------------------------
    // 04 - pdf reader
    try {
      if (!bookRowId) throw new Error('no seeded book — skipping reader open')
      // Disable Detox sync — the PDF reader spins up an internal
      // WebView/native render loop that never goes "quiescent".
      await device.disableSynchronization()
      await waitFor(element(by.id(bookRowId)))
        .toBeVisible()
        .withTimeout(20000)
      await element(by.id(bookRowId)).tap()
      await waitFor(element(by.id('pdf-reader')))
        .toExist()
        .withTimeout(20000)
      // Give the PDF a few seconds to actually render.
      await sleep(3000)
      await device.takeScreenshot('04-pdf-reader')
    } catch (err) {
      console.warn('04-pdf-reader screenshot failed:', err)
      try {
        await device.takeScreenshot('04-pdf-reader-fallback')
      } catch {}
    }

    // -----------------------------------------------------------------
    // 05 - second pdf page
    try {
      // Reveal the toolbar (auto-hides after 3s on mount). Pattern lifted
      // from reader-pdf.test.ts.
      await element(by.id('reader-toggle-toolbar')).tap()
      await sleep(1000)
      await element(by.id('reader-next-page-btn')).tap()
      await sleep(2000)
      await device.takeScreenshot('05-pdf-page-2')
    } catch (err) {
      console.warn('05-pdf-page-2 screenshot failed:', err)
      try {
        await device.takeScreenshot('05-pdf-page-2-fallback')
      } catch {}
    }
  }, 300000)
})
