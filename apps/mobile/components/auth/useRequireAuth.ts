import { useCallback } from 'react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'

/**
 * Gate a premium-feature action behind sign-in.
 *
 * Returns a function that runs `action` immediately when the user is
 * authenticated, otherwise opens the premium-feature sheet for `feature`.
 *
 * Cold-start window (auth not yet hydrated): optimistically run the
 * action — the reactive 401 handler in `lib/api.ts` is the safety net
 * for the brief window where this could be wrong. Better to let a
 * signed-in user proceed than to gate them spuriously on launch.
 */
export function useRequireAuth(
  feature: PremiumFeature,
): (action: () => void) => void {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const openPremiumGate = useAuthStore((s) => s.openPremiumGate)

  return useCallback(
    (action) => {
      if (!authHydrated || isAuthenticated) {
        action()
      } else {
        openPremiumGate(feature)
      }
    },
    [authHydrated, isAuthenticated, openPremiumGate, feature],
  )
}
