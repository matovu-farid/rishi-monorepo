import { useCallback } from 'react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'

/**
 * Gate a premium-feature action behind sign-in.
 *
 * Returns a function that runs `action` immediately when the user is
 * authenticated, otherwise opens the premium-feature sheet for `feature`.
 *
 * Cold-start window (auth not yet hydrated): the trigger is a no-op.
 * We MUST NOT optimistically fire the action — when the user is in fact
 * signed out, that produces raw 401s or silent failures because the
 * premium gate never opens (P0-T). We also do not open the gate yet
 * because the user may actually be signed in; we just don't know until
 * hydration completes. The correct behavior is to defer until we know.
 */
export function useRequireAuth(
  feature: PremiumFeature,
): (action: () => void) => void {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const openPremiumGate = useAuthStore((s) => s.openPremiumGate)

  return useCallback(
    (action) => {
      if (!authHydrated) {
        // Auth state not yet known — defer. Do not fire the action and
        // do not open the gate. The user can retry once hydration lands.
        return
      }
      if (isAuthenticated) {
        action()
      } else {
        // P0-U: forward the action so the store can replay it on
        // successful sign-in. Dismissing the gate ("Not now") discards
        // it via closePremiumGate.
        openPremiumGate(feature, action)
      }
    },
    [authHydrated, isAuthenticated, openPremiumGate, feature],
  )
}
