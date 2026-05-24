import { useCallback, useMemo } from 'react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { useAuthStore } from '@/lib/stores/authStore'

/**
 * Callable returned by `useRequireAuth`. Behaves as a normal function
 * (call it with the action to gate) and carries an `authHydrated`
 * property so the caller can disable / dim the trigger UI while the
 * auth store is still hydrating (GAT-105 / #77). Without that signal
 * the trigger looks active but silently swallows taps during cold
 * start, producing a confusing dead-button state.
 */
export interface RequireAuthGate {
  (action: () => void): void
  /**
   * Mirrors `useAuthStore.authHydrated` at render time. While `false`,
   * invoking the gate is a deliberate no-op (see body comment) — the
   * caller is expected to surface a disabled / loading state.
   */
  readonly authHydrated: boolean
}

/**
 * Gate a premium-feature action behind sign-in.
 *
 * Returns a callable that runs `action` immediately when the user is
 * authenticated, otherwise opens the premium-feature sheet for `feature`.
 *
 * Cold-start window (auth not yet hydrated): the trigger is a no-op.
 * We MUST NOT optimistically fire the action — when the user is in fact
 * signed out, that produces raw 401s or silent failures because the
 * premium gate never opens (P0-T). We also do not open the gate yet
 * because the user may actually be signed in; we just don't know until
 * hydration completes. The correct behavior is to defer until we know.
 *
 * GAT-105 (#77): the returned callable also exposes `authHydrated` so
 * the host UI can dim/disable the premium trigger during that defer
 * window. Previously the hook silently swallowed taps with no visible
 * affordance — users saw an active-looking button do nothing. Callers
 * thread the flag into their `disabled` prop (TTSControls /
 * RealtimeVoiceButton / ChatInput).
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
export function useRequireAuth(feature: PremiumFeature): RequireAuthGate {
  // Subscribe so the hosting component re-renders on auth-state changes.
  // `authHydrated` in particular drives the exposed flag below, which the
  // caller threads into a `disabled` prop — so the parent must re-render
  // the moment hydration lands. The other slice keeps the subscription
  // alive across sign-in / sign-out flips for legacy consumers.
  useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)

  const invoke = useCallback(
    (action: () => void) => {
      // Read the live store on every invocation. The selector
      // subscriptions above keep the parent in sync; the callback
      // itself never reads stale closure values.
      const {
        isAuthenticated,
        authHydrated: liveHydrated,
        openPremiumGate,
      } = useAuthStore.getState()

      if (!liveHydrated) {
        // Auth state not yet known — defer. Do not fire the action and
        // do not open the gate. UI should be disabled via the
        // `authHydrated` flag on the returned callable so the user has
        // a visible affordance instead of a dead tap (GAT-105).
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

  // useMemo so the callable identity is stable while `invoke` and
  // `authHydrated` haven't changed — keeps downstream `useCallback`
  // dependency arrays happy.
  return useMemo<RequireAuthGate>(() => {
    const gate = ((action: () => void) => {
      invoke(action)
    }) as RequireAuthGate
    Object.defineProperty(gate, 'authHydrated', {
      value: authHydrated,
      writable: false,
      enumerable: true,
    })
    return gate
  }, [invoke, authHydrated])
}
