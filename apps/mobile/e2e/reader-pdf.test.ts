/**
 * Reader (PDF) E2E.
 *
 * Mirrors `reader-epub.test.ts` for the PDF route: seed → assert
 * BookRow → tap → assert `pdf-reader` testID on the PDF reader's
 * root View.
 *
 * pdfjs runs inside a WebView too, so we disable Detox sync for the
 * whole suite. The PDF reader sets its testID synchronously on the
 * RN-side root view (not inside the WebView), so finding the element
 * doesn't depend on WebView quiescence.
 */
import { describe, it, beforeAll, expect } from '@jest/globals'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

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

describe('reader: PDF — open from library', () => {
  let bookRowId: string

  beforeAll(async () => {
    await seedBook('pdf')
    bookRowId = fixtureBookRowTestID('pdf')
    await device.disableSynchronization()
  }, 120000)
  // No `afterAll` re-enable: see reader-epub.test.ts for rationale.
  // The next suite's `seedBook` cold-launches with newInstance, which
  // resets Detox sync state.

  it('seeded PDF appears as a BookRow in the library', async () => {
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into the PDF reader route', async () => {
    await element(by.id(bookRowId)).tap()
    await waitFor(element(by.id('pdf-reader')))
      .toExist()
      .withTimeout(20000)
  })

  it('tapping next-page advances the position indicator', async () => {
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).toMatch(/^\d+\/\d+$/)

    // Reveal the toolbar before tapping the next-page button. Phase 3
    // moved the PDF reader onto ReaderShell, whose 3s auto-hide timer
    // arms at mount (initialToolbarVisible=true, ttsActive=false,
    // realtimeActive=false). On slow CI runners the simulator pause
    // before this step can exceed 3s, transitioning the bottom bar to
    // pointerEvents='none' and silently dropping the tap. The MOBI
    // spec compensates with the same reveal step.
    await element(by.id('reader-toggle-toolbar')).tap()
    await new Promise((r) => setTimeout(r, 2000))

    await element(by.id('reader-next-page-btn')).tap()

    let after: string | null = before
    const startedAt = Date.now()
    while (Date.now() - startedAt < 5000) {
      after = await readAccessibilityLabel('reader-position-indicator')
      if (after !== before) break
      await new Promise((r) => setTimeout(r, 250))
    }

    expect(after).not.toBe(before)
    expect(after).toMatch(/^\d+\/\d+$/)
  })
})
