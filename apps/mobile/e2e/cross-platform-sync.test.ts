/**
 * Cross-platform sync — mobile (Detox) half.
 *
 * Pre-conditions (orchestrator's job):
 *   - The mobile app was rebuilt with `EXPO_PUBLIC_E2E_TEST=true` AND
 *     `EXPO_PUBLIC_WORKER_URL=<test worker>` so Metro inlined both into the JS
 *     bundle. (Detox launchArgs cannot flip EXPO_PUBLIC_* at runtime — those
 *     are bake-time per the comment in `.detoxrc.js` lines 7-15.)
 *   - The desktop spec already ran, pushed a book named FIXTURE_TITLE to the
 *     worker, and the orchestrator deleted neither user nor book yet.
 *   - TEST_TOKEN, TEST_USER_ID, TEST_EMAIL, FIXTURE_TITLE env vars are present
 *     in the Detox host process.
 *
 * What this spec does:
 *   1. Cold-launch the app with `rishimobile:///?e2e-action=set-session&...`
 *      so the auth-store hydrates with the worker token.
 *   2. Tap the Library tab to fire `useFocusEffect` (which fires
 *      `startSyncTriggers()` → `sync()`).
 *   3. Bounce through Settings → Library to force a re-fetch of the book
 *      list — the FlatList caches its initial query result.
 *   4. Assert a BookRow appears with `book-row-title` text matching
 *      FIXTURE_TITLE.
 */
import { describe, it, beforeAll } from '@jest/globals'

const TEST_TOKEN = required('TEST_TOKEN')
const TEST_USER_ID = required('TEST_USER_ID')
const TEST_EMAIL = process.env.TEST_EMAIL ?? ''
const FIXTURE_TITLE = required('FIXTURE_TITLE')

function required(name: string): string {
  const v = process.env[name]
  if (!v) {
    throw new Error(`[cross-platform-sync.test] missing env var ${name}`)
  }
  return v
}

describe('cross-platform sync: book imported on electron appears on mobile', () => {
  beforeAll(async () => {
    // Cold-launch with the set-session bridge URL. expo-router's deep-link
    // router routes `/` cleanly; the e2e action handler in `_layout.tsx`
    // picks the bearer + user id out of the query string.
    const url =
      `rishimobile:///?e2e-action=set-session` +
      `&token=${encodeURIComponent(TEST_TOKEN)}` +
      `&user-id=${encodeURIComponent(TEST_USER_ID)}` +
      (TEST_EMAIL ? `&email=${encodeURIComponent(TEST_EMAIL)}` : '')

    await device.launchApp({ newInstance: true, url })

    // The library tab is the default landing in (tabs); wait for it to mount.
    await waitFor(element(by.id('tab-library')))
      .toBeVisible()
      .withTimeout(30_000)
  }, 120_000)

  it('shows the desktop-imported book in the library after first sync', async () => {
    // The first sync fires on `startSyncTriggers()` from (tabs)/_layout.tsx —
    // however, focusing the library tab is what kicks off the FlatList query.
    // Bounce through Settings to force `useFocusEffect` to re-fire on Library.
    await element(by.id('tab-settings')).tap()
    await element(by.id('tab-library')).tap()

    // We don't know the book's id (it was generated on electron), so we
    // match on the title text rendered inside the BookRow. `book-row-title`
    // is a non-unique testID (one per row), so we'd have to combine with
    // `by.text()` to disambiguate; `by.text(FIXTURE_TITLE)` is sufficient
    // and matches Detox's prevailing style elsewhere in this suite.
    await waitFor(element(by.text(FIXTURE_TITLE)))
      .toBeVisible()
      .withTimeout(60_000)
  })
})
