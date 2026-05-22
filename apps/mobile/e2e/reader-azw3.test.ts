/**
 * Reader (AZW3) E2E.
 *
 * AZW3 is stored with format='azw3' and (per Task 0 of the detox-
 * coverage plan) routes through the EPUB reader at `/reader/[id]`.
 * The dispatcher in `app/(tabs)/index.tsx:85-98` falls through to the
 * EPUB route for any format that isn't pdf/mobi/djvu.
 *
 * Scope: this suite verifies import + routing only. Functional
 * navigation (swipe → indicator change) is deferred behind
 * TODO(azw3-rendering) — `@epubjs-react-native/core` expects an EPUB
 * container, and we have not yet verified that it can parse a
 * Kindle-Format-8 AZW3 file. If it cannot, the route will mount but
 * the WebView will show an error / blank — both of which are
 * out-of-scope for this test until empirical verification lands.
 */
import { describe, it, beforeAll } from '@jest/globals'
import { seedBook, fixtureBookRowTestID } from './helpers/seed-book'

describe('reader: AZW3 — open from library', () => {
  let bookRowId: string

  beforeAll(async () => {
    await seedBook('azw3')
    bookRowId = fixtureBookRowTestID('azw3')
    await device.disableSynchronization()
  }, 120000)

  it('seeded AZW3 appears as a BookRow in the library', async () => {
    await waitFor(element(by.id(bookRowId)))
      .toBeVisible()
      .withTimeout(15000)
  })

  it('tapping the BookRow dispatches to the EPUB reader route', async () => {
    await element(by.id(bookRowId)).tap()
    // AZW3 falls through to the EPUB reader per Task 0 finding. Whether
    // the reader can actually render AZW3 content is a separate
    // concern — see TODO(azw3-rendering) in the suite docstring.
    await waitFor(element(by.id('reader-epub')))
      .toExist()
      .withTimeout(20000)
  })

  // TODO(azw3-rendering): once it's confirmed @epubjs-react-native/core
  // can parse AZW3 (or an AZW3→EPUB conversion is added at import time),
  // append a functional-navigation test mirroring reader-epub.test.ts:
  //   - read `reader-position-indicator` label
  //   - swipe('left') on `reader-epub`
  //   - assert indicator changed
  // Until then, the suite stops at routing coverage to avoid false
  // success on unverified rendering.
})
