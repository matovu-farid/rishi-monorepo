/**
 * Reader (DJVU) E2E — DEFERRED.
 *
 * Skipped pending a DJVU fixture. The seed-bridge (e2e/helpers/seed-book.ts,
 * app/_layout.tsx handleE2ESeedLink) already accepts format='djvu',
 * so once a fixture lands at `e2e/fixtures/test-book.djvu`, swap
 * `describe.skip` → `describe` and the suite is live.
 *
 * TODO(djvu-fixture): source a small public-domain DjVu file (e.g.
 * from archive.org's DjVu archive) and commit it as
 * `apps/mobile/e2e/fixtures/test-book.djvu`.
 */
import { describe, it } from '@jest/globals'
import { fixtureBookRowTestID } from './helpers/seed-book'

describe.skip('reader: DJVU — open from library (TODO: needs fixture)', () => {
  it('seeded DJVU appears as a BookRow in the library', async () => {
    const bookRowId = fixtureBookRowTestID('djvu')
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow navigates into the DJVU reader route', async () => {
    const bookRowId = fixtureBookRowTestID('djvu')
    await element(by.id(bookRowId)).tap()
    await waitFor(element(by.id('djvu-reader')))
      .toExist()
      .withTimeout(20000)
  })
})
