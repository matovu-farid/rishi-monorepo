/**
 * Reader (MOBI) E2E.
 *
 * Mirrors `reader-epub.test.ts` for the MOBI route. The MOBI reader
 * runs its own parser inside a WebView (decompresses PalmDOC and
 * renders chapters), so Detox sync is disabled at the suite level.
 * The `mobi-reader` testID is set on the RN-side root View, which
 * mounts before the WebView starts work — finding it is independent
 * of WebView quiescence.
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
  return attrs.label ?? attrs.text ?? null
}

describe('reader: MOBI — open from library', () => {
  let bookRowId: string

  beforeAll(async () => {
    await seedBook('mobi')
    bookRowId = fixtureBookRowTestID('mobi')
    await device.disableSynchronization()
  }, 120000)
  // No `afterAll` re-enable: see reader-epub.test.ts for rationale.
  // The next suite's `seedBook` cold-launches with newInstance, which
  // resets Detox sync state.

  it('seeded MOBI appears as a BookRow in the library', async () => {
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into the MOBI reader route', async () => {
    await element(by.id(bookRowId)).tap()
    await waitFor(element(by.id('mobi-reader')))
      .toExist()
      .withTimeout(20000)
  })

  it('tapping next-chapter advances the position indicator', async () => {
    const before = await readAccessibilityLabel('reader-position-indicator')
    expect(before).toMatch(/^\d+\/\d+$/)

    // Reveal the toolbar (single tap on the reader root toggles it).
    await element(by.id('mobi-reader')).tap()

    // Wait briefly for the toolbar animation; toolbar mounts the next
    // button synchronously once toolbarVisible flips true.
    await new Promise((r) => setTimeout(r, 500))

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
