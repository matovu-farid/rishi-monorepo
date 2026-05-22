/**
 * Auth flow E2E.
 *
 * In E2E mode (`EXPO_PUBLIC_E2E_TEST=true` baked into the Release bundle
 * by Detox's build step), the sign-in screen is bypassed and the app
 * lands on the Library tab — see `app/(tabs)/_layout.tsx` and
 * `app/_layout.tsx`. So the things we CAN verify from a Detox test
 * without rebuilding without the bypass:
 *
 *   1. The bypass works (covered indirectly by smoke + library tests).
 *   2. The sign-in screen renders when navigated to directly via the
 *      file-system route, IF the route is reachable. expo-router treats
 *      route groups in parens as transparent, so `/(auth)/sign-in` does
 *      not match a URL; but we can still mount it via deep link if a
 *      scheme entry is registered. The current app does not have one
 *      for the in-app sign-in route — only for the OAuth callback.
 *
 * Therefore the real auth UI tests are deferred to a build variant
 * (`EXPO_PUBLIC_E2E_TEST=false` + manually-cleared session) which is
 * out of scope for Wave 1.
 *
 * What we DO test here: when the bypass is enabled, the user never sees
 * the sign-in screen and goes straight to the library.
 */
import { describe, it } from '@jest/globals';

describe('auth: E2E bypass behavior', () => {
  it('does NOT render the sign-in screen on cold launch', async () => {
    // If the bypass had failed, the sign-in screen's testID would be
    // visible. Assert it is absent.
    await expect(element(by.id('sign-in-title'))).not.toBeVisible();
    await expect(element(by.text('Welcome to Rishi'))).not.toBeVisible();
  });

  it('lands on the Library tab (proves auth bypass succeeded)', async () => {
    await expect(element(by.id('tab-library'))).toBeVisible();
    await expect(element(by.id('library-empty-state'))).toBeVisible();
  });
});

describe.skip('auth: real sign-in UI (TODO — requires a second build variant)', () => {
  // To exercise the real sign-in UI we need a build with
  // `EXPO_PUBLIC_E2E_TEST` unset or `EXPO_PUBLIC_FORCE_SIGN_IN=true` so
  // the `(tabs)/_layout.tsx` Redirect to `/(auth)/sign-in` fires. Either
  // approach requires either a second Detox configuration with its own
  // build, or runtime flag plumbing through Detox `launchArgs`. Wave 2
  // task.
  it.skip('renders "Welcome to Rishi" title', async () => {});
  it.skip('renders Google sign-in button', async () => {});
  it.skip('renders email sign-in button', async () => {});
  it.skip('shows error text when signIn rejects', async () => {});
});
