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
    // The MOBI parser runs inside a WebView and fires its `loaded`
    // message asynchronously. Until then, `chapterCount` is 0, which
    // makes the next-chapter button `disabled` (opacity 0.3) — that
    // fails Detox's 100% visibility threshold check. Poll the
    // indicator until it reports more than one chapter (single-chapter
    // books also leave the button disabled).
    let before: string | null = '0/0'
    const baselineStartedAt = Date.now()
    while (Date.now() - baselineStartedAt < 20000) {
      before = await readAccessibilityLabel('reader-position-indicator')
      const match = before && before.match(/^\d+\/(\d+)$/)
      if (match && parseInt(match[1], 10) > 1) break
      await new Promise((r) => setTimeout(r, 500))
    }
    expect(before).toMatch(/^\d+\/\d+$/)
    const beforeMatch = before && before.match(/^\d+\/(\d+)$/)
    expect(beforeMatch && parseInt(beforeMatch[1], 10) > 1).toBe(true)

    // Reveal the toolbar by tapping the dedicated toolbar-toggle
    // TouchableOpacity. The mobi-reader container view fails Detox's
    // 100% visibility check because the WebView occludes most of its
    // bounds, so we cannot tap or tapAtPoint on it directly.
    await element(by.id('reader-toggle-toolbar')).tap()

    // Wait for the toolbar mount + iOS Fabric layout/draw commit. The
    // bottom toolbar SafeAreaView is dynamically inserted above the
    // WebView when toolbarVisible flips — Detox's 100% visibility
    // check on the next-page button fails until the new view tree has
    // fully settled.
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
