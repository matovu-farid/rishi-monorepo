/**
 * Reader (EPUB) E2E.
 *
 * Flow:
 *   1. Host pushes `test-book.epub` into the simulator app's Documents.
 *   2. `device.launchApp({ url })` cold-launches with the seed URL —
 *      `_layout.tsx`'s `getInitialURL` handler imports the file via
 *      the real import service.
 *   3. We round-trip Settings → Library to re-fire `useFocusEffect` so
 *      the FlatList picks up the new row.
 *   4. Tap the BookRow → assert the reader route mounts via the
 *      `reader-epub` testID on `ReaderContent`'s root view.
 *
 * Synchronization: the epubjs WebView keeps the JS thread busy for
 * seconds after mount, which makes Detox's auto-wait stall any
 * subsequent matcher. We disable sync for the whole suite (the only
 * UI we assert on is the reader root testID, which is set
 * synchronously by RN — it doesn't need bridge quiescence). We do
 * NOT re-enable sync in `afterAll`: `enableSynchronization()` waits
 * for the app to go idle, which the epubjs WebView never does, so
 * the hook would hang for its full timeout. The next suite's
 * `seedBook` cold-launches with `newInstance: true` which resets
 * sync state anyway.
 *
 * Out of scope (parity with electron's `epub-reader.spec.ts` later):
 *   - In-WebView text selection, scroll position, CFI persistence,
 *     TOC navigation. These need a JS bridge into the epubjs WebView
 *     that does not exist yet.
 */
import { describe, it, beforeAll, expect } from '@jest/globals'
import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import * as fs from 'fs'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

const execFile = promisify(execFileCb)
const SCREENSHOT_DIR = '/tmp/rishi-epub-debug'

async function captureScreenshot(name: string): Promise<string> {
  if (!fs.existsSync(SCREENSHOT_DIR)) fs.mkdirSync(SCREENSHOT_DIR, { recursive: true })
  const dest = `${SCREENSHOT_DIR}/${name}.png`
  await execFile('xcrun', ['simctl', 'io', 'booted', 'screenshot', dest])
  return dest
}

/**
 * Read the accessibilityLabel of a testID-matched element. Detox does
 * not expose a direct "read label" API, so we use the attributes
 * snapshot. iOS returns labels under `label` (singular). Returns
 * `null` if the element cannot be resolved.
 */
async function readAccessibilityLabel(testID: string): Promise<string | null> {
  const attrs = (await element(by.id(testID)).getAttributes()) as
    | { label?: string; text?: string }
    | null
    | undefined
  if (!attrs) return null
  // iOS shape: `{ label: '...' }`. Android (when added later): `{ text: '...' }`.
  return attrs.label ?? attrs.text ?? null
}

describe('reader: EPUB — open from library', () => {
  let bookRowId: string

  beforeAll(async () => {
    await seedBook('epub')
    bookRowId = fixtureBookRowTestID('epub')
    await device.disableSynchronization()
  }, 120000)

  it('seeded EPUB appears as a BookRow in the library', async () => {
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into the reader route', async () => {
    await element(by.id(bookRowId)).tap()
    await waitFor(element(by.id('reader-epub')))
      .toExist()
      .withTimeout(20000)
  })

  // Regression guard: prior to memoizing `defaultTheme` (and similar
  // unstable prop refs) in `ReaderContent`, the epubjs Reader entered
  // an infinite render loop on mount and never fired onLocationChange.
  // The position indicator stayed at its fallback 'unknown'.
  it('EPUB content renders (position indicator transitions away from "unknown")', async () => {
    let label: string | null = 'unknown'
    const startedAt = Date.now()
    while (Date.now() - startedAt < 30000) {
      label = await readAccessibilityLabel('reader-position-indicator')
      if (label && label !== 'unknown') break
      await new Promise((r) => setTimeout(r, 500))
    }
    const shot = await captureScreenshot('epub-loaded')
    console.log(`[reader-epub] screenshot: ${shot}, label: ${String(label)}`)
    expect(label).not.toBeNull()
    expect(label).not.toBe('unknown')
  })

  // Skipped (separate concern): asserting swipe advances the CFI is a
  // followup once the WebView gesture bridge is stable.
  it.skip('swiping advances to the next page (CFI indicator updates)', async () => {
    let before: string | null = 'unknown'
    const baselineStartedAt = Date.now()
    while (Date.now() - baselineStartedAt < 25000) {
      before = await readAccessibilityLabel('reader-position-indicator')
      if (before && before !== 'unknown') break
      await new Promise((r) => setTimeout(r, 500))
    }
    expect(before).not.toBeNull()
    expect(before).not.toBe('unknown')

    await element(by.id('reader-epub')).swipe('left', 'fast', 0.8, 0.2, 0.5)

    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
  })
})
