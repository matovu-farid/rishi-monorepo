/**
 * Snapshot of compile-time feature flags shipped with the mobile app.
 *
 * APPLE_SIGNIN_ENABLED gates the iOS "Continue with Apple" CTA in
 * PremiumFeatureSheet. The Apple OAuth provider is not yet provisioned
 * in the mobile worker/app pair (P0-V), so this MUST default to false —
 * flipping it to true is the single switch that re-enables the Apple
 * branch once credentials are wired up.
 */
import * as featureFlags from '@/lib/feature-flags'

describe('feature-flags', () => {
  it('APPLE_SIGNIN_ENABLED is exported and defaults to false (P0-V)', () => {
    expect(featureFlags).toHaveProperty('APPLE_SIGNIN_ENABLED')
    expect(featureFlags.APPLE_SIGNIN_ENABLED).toBe(false)
  })
})
