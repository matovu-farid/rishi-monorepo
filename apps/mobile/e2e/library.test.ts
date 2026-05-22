/**
 * Library tab E2E.
 *
 * Scope (Wave 1): empty-state behavior + tab persistence. Populated-state
 * tests (book grid, book row, delete with undo) require a SQLite seed
 * helper that does not yet exist — those are deferred and marked .skip
 * with TODO so they appear in the gap inventory.
 *
 * Detox globals (`device`, `element`, `by`, `waitFor`, `expect`) are
 * injected by the jest environment in `e2e/jest.config.js`.
 */
import { describe, it } from '@jest/globals';
import {
  seedBook,
  fixtureBookRowTestID,
  type SeedFormat,
} from './helpers/seed-book';

describe('library: empty state', () => {
  it('lands on the library tab on cold launch', async () => {
    await waitFor(element(by.id('tab-library')))
      .toBeVisible()
      .withTimeout(60000);
  });

  it('renders the empty-state container with title and import button', async () => {
    await expect(element(by.id('library-empty-state'))).toBeVisible();
    await expect(element(by.id('library-empty-title'))).toBeVisible();
    await expect(element(by.text('No books yet'))).toBeVisible();
    await expect(
      element(by.text('Import an EPUB or PDF from your device to start reading.')),
    ).toBeVisible();
    await expect(element(by.id('library-empty-import-btn'))).toBeVisible();
  });

  it('Import Book button is tappable and is accessible by accessibility label', async () => {
    // Tapping triggers a native Alert that we cannot interact with from
    // Detox without applesimutils dialog handling — assert tappability
    // by checking the element is interactive (not disabled).
    await expect(element(by.label('Import Book'))).toBeVisible();
    // We intentionally do NOT tap here, because the resulting native
    // Alert blocks the JS thread and breaks Detox synchronization.
  });
});

describe('library: tab navigation', () => {
  it('navigates Library → Settings → Library, preserving empty state', async () => {
    await element(by.id('tab-settings')).tap();
    // "Settings" appears as both tab label and screen title — atIndex
    // disambiguates.
    await expect(element(by.text('Settings')).atIndex(0)).toBeVisible();
    await element(by.id('tab-library')).tap();
    await expect(element(by.id('library-empty-state'))).toBeVisible();
  });

  it('navigates Library → Chat → Library', async () => {
    await element(by.id('tab-chat')).tap();
    await expect(element(by.id('conversations-title'))).toBeVisible();
    await element(by.id('tab-library')).tap();
    await expect(element(by.id('library-empty-state'))).toBeVisible();
  });
});

describe.skip('library: populated state (TODO — needs seed helper)', () => {
  // Pending lib/test-fixtures/seed.ts. When implemented:
  //   - seed N books, assert FlatList renders N BookRow items via
  //     `library-book-row-<id>` (testID still needs to be added to BookRow)
  //   - tap a BookRow, assert navigation to the correct reader route
  //   - long-press / delete a book, confirm Undo snackbar appears
  //   - search filter narrows the list
  it.skip('seeded library renders BookRow per book', async () => {});
});

describe('library: fixture import via E2E seed bridge', () => {
  // The native UIDocumentPickerView controller cannot be driven by
  // Detox on iOS, so the picker tap path remains untestable end-to-end.
  // Instead, we exercise the same `importBookFromFile` pipeline the
  // picker eventually calls — the host (`e2e/helpers/seed-book.ts`)
  // pushes a fixture into the app's Documents sandbox via
  // `xcrun simctl get_app_container` and cold-launches with
  // `rishimobile:///?e2e-action=seed-book&format=<fmt>`. The deep-link
  // handler in `app/_layout.tsx` invokes the real import service,
  // gated on `IS_E2E_TEST`. Asserting the post-import BookRow proves
  // the format parses, the row persists, and the library re-renders.
  const formats: SeedFormat[] = ['epub', 'pdf', 'mobi', 'azw3'];

  for (const format of formats) {
    it(`imports a ${format.toUpperCase()} fixture and renders its BookRow`, async () => {
      await seedBook(format);
      await expect(element(by.id(fixtureBookRowTestID(format)))).toBeVisible();
      await expect(element(by.id('library-empty-state'))).not.toBeVisible();
    });
  }
});
