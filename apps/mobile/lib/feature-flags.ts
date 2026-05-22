/**
 * Compile-time feature flags for the Rishi mobile app.
 *
 * Flags here are intentionally plain constants (not env-driven) so the
 * Metro bundler can dead-code-eliminate disabled branches. Flip a flag
 * by editing this file and shipping a new build.
 */

/**
 * Gates the "Continue with Apple" CTA on iOS in `PremiumFeatureSheet`.
 *
 * Default: `false`. Apple OAuth is not yet provisioned in the mobile
 * worker + app pair (no Apple Services ID / Sign-in-with-Apple
 * credentials wired up), so tapping the Apple button would produce a
 * broken sign-in flow (P0-V). Until provisioning lands we ship Google
 * universally; users who want email-based sign-in can deep-link from
 * the sheet into `/(auth)/sign-in`.
 *
 * When Apple OAuth IS provisioned, flip this to `true` and the iOS
 * Apple branch in `PremiumFeatureSheet` re-enables automatically.
 */
export const APPLE_SIGNIN_ENABLED = false
