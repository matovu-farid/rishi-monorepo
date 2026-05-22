/**
 * Smoke test for rishi-mobile.
 *
 * Purpose: verify the app boots into the (tabs) layout under E2E mode
 * and renders the bottom tab bar. This is the foundation that Wave 1
 * feature tests will build on — if this is red, every other test is
 * meaningless.
 *
 * Globals (`device`, `element`, `by`, `expect`) are injected by the
 * Detox jest environment. `expect` here is Detox's matcher (which
 * returns a promise), NOT Jest's `expect` — do not import jest's
 * `expect` in this file.
 */
import { describe, it } from '@jest/globals';

describe('smoke: app boot', () => {
  it('launches into the tabs layout', async () => {
    // The Library tab is the default landing tab, so its button is the
    // most reliable "did the app finish booting" signal we have without
    // a dedicated root testID. If E2E mode were misconfigured we'd be
    // stuck on the sign-in screen and this would fail.
    await waitFor(element(by.id('tab-library')))
      .toBeVisible()
      .withTimeout(60000);
  });

  it('renders the Library, Chat, and Settings tabs', async () => {
    await expect(element(by.id('tab-library'))).toBeVisible();
    await expect(element(by.id('tab-chat'))).toBeVisible();
    await expect(element(by.id('tab-settings'))).toBeVisible();

    // Label-based assertions as a belt-and-braces check. If a future
    // refactor accidentally drops the testIDs, these still tell us the
    // user-visible labels are intact.
    await expect(element(by.text('Library'))).toBeVisible();
    await expect(element(by.text('Chat'))).toBeVisible();
    await expect(element(by.text('Settings'))).toBeVisible();
  });
});
