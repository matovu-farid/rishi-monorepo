/**
 * Settings tab E2E.
 *
 * Scope: assert all three sections (Account, Voice, About) render with
 * their controls, and that toggles are interactive. Sign-out is exercised
 * here because the auth flow ends at "Not signed in" when E2E mode is on
 * and there's no real session.
 */
import { describe, it } from '@jest/globals';

describe('settings: structure', () => {
  it('navigates to the Settings tab', async () => {
    await element(by.id('tab-settings')).tap();
    // The bare-text "Settings" matches both the tab label and the
    // screen title, so use atIndex to disambiguate.
    await expect(element(by.text('Settings')).atIndex(0)).toBeVisible();
  });

  it('renders the Account section', async () => {
    // Section header uses NativeWind `uppercase`, which RN renders as
    // CSS text-transform — the on-screen string is "ACCOUNT".
    await expect(element(by.text('ACCOUNT'))).toBeVisible();
    // In E2E mode the bypass skips real auth; user is null, so the
    // "Not signed in." copy is what we should see.
    await expect(element(by.text('Not signed in.'))).toBeVisible();
    await expect(element(by.id('settings-sign-out'))).toBeVisible();
  });

  it('renders the Voice section with language picker + two toggles', async () => {
    await expect(element(by.text('VOICE'))).toBeVisible();
    await expect(element(by.text('Voice chat language'))).toBeVisible();
    await expect(element(by.id('settings-language-picker'))).toBeVisible();
    await expect(element(by.id('settings-vision-toggle'))).toBeVisible();
    await expect(element(by.id('settings-tts-cue-toggle'))).toBeVisible();
  });

  it('renders the About section with version, platform, replay tutorial', async () => {
    // Above-the-fold items must be visible. The "Replay tutorial"
    // button at the very bottom of the ScrollView is sometimes
    // partially clipped on iPhone-sized screens; assert it exists in
    // the tree (which proves the About section rendered fully) without
    // requiring 75% viewport visibility.
    await expect(element(by.text('ABOUT'))).toBeVisible();
    await expect(element(by.text('App version'))).toBeVisible();
    await expect(element(by.id('settings-app-version'))).toBeVisible();
    await expect(element(by.text('Platform'))).toBeVisible();
    await expect(element(by.text('ios'))).toBeVisible();
    await expect(element(by.id('settings-replay-tutorial'))).toExist();
  });
});

describe('settings: interactions', () => {
  beforeAll(async () => {
    // Ensure we're on Settings even if a prior describe block left us
    // somewhere else.
    await element(by.id('tab-settings')).tap();
  });

  it('toggles the vision switch', async () => {
    // Detox `toggle()` does not exist; tapping a Switch flips it.
    await element(by.id('settings-vision-toggle')).tap();
    // Tap again to flip back so subsequent runs find a stable state.
    await element(by.id('settings-vision-toggle')).tap();
  });

  it('toggles the TTS visual-cue switch', async () => {
    await element(by.id('settings-tts-cue-toggle')).tap();
    await element(by.id('settings-tts-cue-toggle')).tap();
  });

  it('Sign out button is tappable when not signed in', async () => {
    // In E2E mode with no real session, sign-out is a no-op (clearSession
    // on a null session). We assert it doesn't crash and we stay put on
    // the Settings screen — use the Voice section header as a stable
    // post-tap signal (single occurrence on the page).
    await element(by.id('settings-sign-out')).tap();
    await expect(element(by.text('VOICE'))).toBeVisible();
  });
});

describe.skip('settings: language picker selection (TODO)', () => {
  // The LanguagePicker uses a custom popover. Need to inspect its testIDs
  // before driving it via Detox. Deferred until the picker component is
  // audited.
  it.skip('changes voice chat language', async () => {});
});
