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
 *
 * CHT-008 (#58): the gate function reads auth state from
 * `useAuthStore.getState()` at invocation time rather than from a
 * closure captured at hook construction. The previous implementation
 * snapshotted `isAuthenticated` / `authHydrated` via selectors and
 * baked those values into the returned callback's closure — if the
 * store flipped between the most recent render and the user's tap, the
 * gate observed the stale snapshot. Reading `getState()` on each call
 * makes the gate self-healing: even a long-lived callback always sees
 * the live store.
 */
export function useRequireAuth(
  feature: PremiumFeature,
): (action: () => void) => void {
  // Subscribe so the hosting component still re-renders when auth state
  // changes (downstream consumers like ChatInput's `disabled` prop rely
  // on this). The values aren't used in the callback body — the
  // callback reads the live store instead — but keeping the subscription
  // here means the component still updates when sign-in lands.
  useAuthStore((s) => s.isAuthenticated)
  useAuthStore((s) => s.authHydrated)

  return useCallback(
    (action) => {
      // Read the live store on every invocation. The selector
      // subscriptions above keep the parent in sync; the callback
      // itself never reads stale closure values.
      const { isAuthenticated, authHydrated, openPremiumGate } =
        useAuthStore.getState()

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
    [feature],
  )
}
