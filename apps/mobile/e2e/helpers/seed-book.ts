/**
 * Host-side helper for seeding a real book fixture into the running
 * Detox app. The flow:
 *
 *   1. Copy `e2e/fixtures/test-book.<format>` into the booted
 *      simulator's app-data sandbox under `Documents/test-book.<format>`
 *      (the same location `Paths.document` inside the app exposes).
 *   2. Open a `rishimobile://e2e/seed-book?format=<format>` deep link
 *      so `app/_layout.tsx`'s E2E URL handler imports the file via the
 *      real `createMobileBookImportService` pipeline.
 *   3. Poll for the seeded book row by id (`e2e-fixture-book-<format>`)
 *      to appear in the library UI before returning.
 *
 * The deep-link is fire-and-forget — Detox cannot await a JS-side
 * response. The caller waits on the UI side-effect (a BookRow with the
 * deterministic id), which is the closest "import done" signal we have.
 */
import { execFile as execFileCb } from 'child_process'
import { promisify } from 'util'
import * as path from 'path'

const execFile = promisify(execFileCb)

const BUNDLE_ID = 'com.rishi.mobile'
const FIXTURES_DIR = path.resolve(__dirname, '..', 'fixtures')

export type SeedFormat = 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'

/**
 * The deterministic book id the in-app seeder will use.
 * Mirrors `fixtureBookId(format)` in `lib/test-fixtures/seed.ts`.
 */
export function fixtureBookId(format: SeedFormat): string {
  return `e2e-fixture-book-${format}`
}

/**
 * The expected testID of the seeded book's BookRow in the library.
 * (BookRow uses `library-book-row-${id}` per the spec — wave 1 follow-up
 * adds the testID if it isn't present yet.)
 */
export function fixtureBookRowTestID(format: SeedFormat): string {
  return `library-book-row-${fixtureBookId(format)}`
}

/**
 * Get the booted simulator's app-data container directory. Errors if
 * no sim is booted or the app isn't installed.
 */
async function getAppDataDir(): Promise<string> {
  const { stdout } = await execFile('xcrun', [
    'simctl',
    'get_app_container',
    'booted',
    BUNDLE_ID,
    'data',
  ])
  return stdout.trim()
}

/**
 * Copy the fixture file into the running app's Documents directory.
 * Idempotent — overwrites any prior copy.
 */
async function pushFixture(format: SeedFormat): Promise<void> {
  const fixturePath = path.join(FIXTURES_DIR, `test-book.${format}`)
  const appData = await getAppDataDir()
  const dest = path.join(appData, 'Documents', `test-book.${format}`)
  // `cp -f` overwrites and avoids a "destination exists" prompt. We use
  // `execFile` (not `exec`) so no shell interpolation runs on the paths.
  await execFile('cp', ['-f', fixturePath, dest])
}

/**
 * Seed a real book of the given format into the running app and wait
 * for the library to surface it. Returns the deterministic book id so
 * the calling test can build matchers from it.
 *
 * Pre-conditions: a Detox build is running on the booted iPhone 17
 * simulator. The fixture file exists at `e2e/fixtures/test-book.<ext>`.
 */
export async function seedBook(format: SeedFormat): Promise<string> {
  await pushFixture(format)
  // Cold-launch the app with the seed URL as the initial URL — this is
  // the only Detox-iOS-supported way to deliver a deep link the app's
  // `Linking.getInitialURL()` will see. `device.openURL` does not
  // dispatch reliably to the `Linking` listener on iOS simulators.
  await device.launchApp({
    newInstance: true,
    url: `rishimobile:///?e2e-action=seed-book&format=${format}`,
  })

  const bookId = fixtureBookId(format)
  await waitFor(element(by.id('tab-library')))
    .toBeVisible()
    .withTimeout(30000)
  // The deep-link handler runs the import asynchronously after the
  // (tabs) layout has already mounted and called `getBooks()` once.
  // Tapping the same tab you're on does NOT re-fire `useFocusEffect`,
  // so the seeded row never appears unless we navigate away and back.
  // Round-trip via Settings to force a fresh focus-effect on Library.
  await element(by.id('tab-settings')).tap()
  await element(by.id('tab-library')).tap()
  await waitFor(element(by.id(fixtureBookRowTestID(format))))
    .toBeVisible()
    .withTimeout(30000)
  return bookId
}
