/**
 * Tests for the mobile authStore (ported from electron).
 *
 * Same shape as electron: tracks `user`, `welcomeSeen`, `bannerDismissed`,
 * `signInOpen`, `authHydrated`. Persists `welcomeSeen` to MMKV (electron
 * persists it to localStorage). Token persistence is NOT in this store —
 * `lib/auth.ts` owns the JWT via expo-secure-store.
 *
 * Tutorial-tour integration is preserved: dismissing the welcome banner
 * after sign-up triggers the tour via tutorialStore.
 */

// ── Mock react-native-mmkv (in-memory fallback so the storage module loads) ──
type StoreBackend = Map<string, string>
let backingStore: StoreBackend

function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => {
      store.set(key, String(value))
    },
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

// authStore.hydrateAuth (H1-04) calls into lib/auth.getSessionToken which
// pulls expo-crypto/expo-secure-store/expo-web-browser. Mock the surface
// directly so this test stays focused on store behaviour.
jest.mock('@/lib/auth', () => ({
  getSessionToken: jest.fn(async () => null),
}))

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
  // Quiet the timer used by dismissWelcome → startTour scheduling.
  jest.useFakeTimers()
})

afterEach(() => {
  jest.useRealTimers()
})

describe('authStore (mobile)', () => {
  it('defaults: user=null, authHydrated=false, modals closed', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    const s = useAuthStore.getState()
    expect(s.user).toBeNull()
    expect(s.authHydrated).toBe(false)
    expect(s.welcomeSeen).toBe(false)
    expect(s.bannerDismissed).toBe(false)
    expect(s.signInOpen).toBe(false)
  })

  it('setUser stores the AuthUser', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setUser({ id: '123', email: 'a@b.com' })
    const u = useAuthStore.getState().user
    expect(u?.id).toBe('123')
    expect(u?.email).toBe('a@b.com')
  })

  it('setAuthHydrated flips the flag', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setAuthHydrated(true)
    expect(useAuthStore.getState().authHydrated).toBe(true)
  })

  it('hydrateAuth() reads welcomeSeen=true from MMKV when the flag is "1"', () => {
    backingStore.set('rishi.mobile.auth:welcome-seen', '1')
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
  })

  it('hydrateAuth() defaults welcomeSeen=false when nothing is persisted', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().welcomeSeen).toBe(false)
  })

  it('dismissBanner sets bannerDismissed=true without touching welcomeSeen', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().dismissBanner()
    expect(useAuthStore.getState().bannerDismissed).toBe(true)
    expect(useAuthStore.getState().welcomeSeen).toBe(false)
  })

  it('dismissWelcome persists welcomeSeen=1, dismisses banner, schedules tour', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    const startTourSpy = jest.spyOn(useTutorialStore.getState(), 'startTour')

    useAuthStore.getState().dismissWelcome()
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
    expect(useAuthStore.getState().bannerDismissed).toBe(true)
    expect(backingStore.get('rishi.mobile.auth:welcome-seen')).toBe('1')

    // Tour kicks off after a 400ms delay
    jest.advanceTimersByTime(400)
    expect(startTourSpy).toHaveBeenCalledTimes(1)
  })

  it('setWelcomeSeen persists welcomeSeen=1 (no banner dismissal)', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setWelcomeSeen()
    expect(useAuthStore.getState().welcomeSeen).toBe(true)
    expect(backingStore.get('rishi.mobile.auth:welcome-seen')).toBe('1')
  })

  it('openSignIn / closeSignIn toggles signInOpen', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().openSignIn()
    expect(useAuthStore.getState().signInOpen).toBe(true)
    useAuthStore.getState().closeSignIn()
    expect(useAuthStore.getState().signInOpen).toBe(false)
  })

  it('dismissWelcome does not re-trigger the tour if it was already completed', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.setState({ tourCompleted: true })
    const startTourSpy = jest.spyOn(useTutorialStore.getState(), 'startTour')

    useAuthStore.getState().dismissWelcome()
    jest.advanceTimersByTime(400)
    expect(startTourSpy).not.toHaveBeenCalled()
  })

  // ── Batch 1C: session-token surface ───────────────────────────────────────
  it('exposes sessionToken=null and isAuthenticated=false by default', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    const s = useAuthStore.getState()
    expect(s.sessionToken).toBeNull()
    expect(s.isAuthenticated).toBe(false)
    expect(s.isAuthenticating).toBe(false)
  })

  it('setSession(token, userId) records the token, user id and flips isAuthenticated', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setSession('tok-1', 'user-1')
    const s = useAuthStore.getState()
    expect(s.sessionToken).toBe('tok-1')
    expect(s.user?.id).toBe('user-1')
    expect(s.isAuthenticated).toBe(true)
  })

  it('setSession persists the user id to MMKV (token stays in secure-store)', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setSession('tok-1', 'user-42')
    expect(backingStore.get('rishi.mobile.auth:user-id')).toBe('user-42')
    // Token must NOT leak into MMKV — it lives in expo-secure-store only.
    for (const [k] of backingStore.entries()) {
      expect(k).not.toMatch(/token|bearer/i)
    }
  })

  it('clearSession() resets sessionToken, user and isAuthenticated', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setSession('tok-1', 'user-1')
    useAuthStore.getState().clearSession()
    const s = useAuthStore.getState()
    expect(s.sessionToken).toBeNull()
    expect(s.user).toBeNull()
    expect(s.isAuthenticated).toBe(false)
    expect(backingStore.get('rishi.mobile.auth:user-id')).toBeUndefined()
  })

  it('setAuthenticating toggles isAuthenticating', () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().setAuthenticating(true)
    expect(useAuthStore.getState().isAuthenticating).toBe(true)
    useAuthStore.getState().setAuthenticating(false)
    expect(useAuthStore.getState().isAuthenticating).toBe(false)
  })

  it('hydrateAuth() restores the persisted user id from MMKV', () => {
    backingStore.set('rishi.mobile.auth:user-id', 'persisted-user')
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().user?.id).toBe('persisted-user')
  })

  // ── P0-U: gated-action replay on sign-in ──────────────────────────────────
  //
  // When a signed-out user taps a gated control (e.g. send in chat), the
  // caller passes the would-be action into `openPremiumGate(feature, action)`.
  // The store stashes the action; on successful sign-in (`setSession`) the
  // store replays the action and clears the slot. If the user dismisses
  // the gate first (`closePremiumGate`), the action is discarded WITHOUT
  // being invoked.
  describe('pendingAction (P0-U)', () => {
    it('defaults pendingAction to null', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      expect(useAuthStore.getState().pendingAction).toBeNull()
    })

    it('openPremiumGate(feature, action) stashes the action without invoking it', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      const action = jest.fn()
      useAuthStore.getState().openPremiumGate('ai-chat', action)
      expect(useAuthStore.getState().pendingAction).toBe(action)
      expect(action).not.toHaveBeenCalled()
      expect(useAuthStore.getState().premiumGateOpen).toBe(true)
      expect(useAuthStore.getState().premiumGateFeature).toBe('ai-chat')
    })

    it('openPremiumGate(feature) (no action) still opens the gate', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      useAuthStore.getState().openPremiumGate('tts')
      expect(useAuthStore.getState().premiumGateOpen).toBe(true)
      expect(useAuthStore.getState().pendingAction).toBeNull()
    })

    it('setSession() replays the stashed action and clears it', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      const action = jest.fn()
      useAuthStore.getState().openPremiumGate('ai-chat', action)
      useAuthStore.getState().setSession('tok', 'user-1')
      expect(action).toHaveBeenCalledTimes(1)
      expect(useAuthStore.getState().pendingAction).toBeNull()
    })

    it('closePremiumGate() discards the stashed action WITHOUT invoking it', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      const action = jest.fn()
      useAuthStore.getState().openPremiumGate('ai-chat', action)
      useAuthStore.getState().closePremiumGate()
      expect(action).not.toHaveBeenCalled()
      expect(useAuthStore.getState().pendingAction).toBeNull()
      expect(useAuthStore.getState().premiumGateOpen).toBe(false)
    })

    it('setSession() with no pendingAction is a no-op for the slot', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      expect(() => {
        useAuthStore.getState().setSession('tok', 'user-1')
      }).not.toThrow()
      expect(useAuthStore.getState().pendingAction).toBeNull()
    })
  })

  // P1-R — dismissedFeatures. When the user explicitly dismisses the
  // premium gate (Maybe later / backdrop tap), the feature they tapped
  // is recorded in a session-only Set. Surfaces (reader, chat) consult
  // this set and hide / disable the gated control so the gate cannot be
  // re-triggered until the next cold start.
  describe('dismissedFeatures (P1-R)', () => {
    it('defaults dismissedFeatures to an empty Set', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      const s = useAuthStore.getState()
      expect(s.dismissedFeatures).toBeInstanceOf(Set)
      expect(s.dismissedFeatures.size).toBe(0)
    })

    it('closePremiumGate() with an active feature adds it to dismissedFeatures', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      useAuthStore.getState().openPremiumGate('tts')
      useAuthStore.getState().closePremiumGate()
      expect(useAuthStore.getState().dismissedFeatures.has('tts')).toBe(true)
    })

    it('closePremiumGate() with no active feature is a no-op for the set', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      useAuthStore.getState().closePremiumGate()
      expect(useAuthStore.getState().dismissedFeatures.size).toBe(0)
    })

    it('setSession() (successful sign-in) clears dismissedFeatures', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      useAuthStore.getState().openPremiumGate('tts')
      useAuthStore.getState().closePremiumGate()
      expect(useAuthStore.getState().dismissedFeatures.has('tts')).toBe(true)
      useAuthStore.getState().setSession('tok', 'user-1')
      expect(useAuthStore.getState().dismissedFeatures.size).toBe(0)
    })

    // GAT-101 (#74) — explicit sign-out must wipe dismissedFeatures so that
    // a subsequent sign-in as a different user does not inherit the previous
    // user's session dismissals.
    it('clearSession() (explicit sign-out) clears dismissedFeatures (#74)', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      // Seed an authenticated session and a dismissed feature.
      useAuthStore.getState().setSession('tok-1', 'user-a')
      useAuthStore.getState().openPremiumGate('tts')
      useAuthStore.getState().closePremiumGate()
      expect(useAuthStore.getState().dismissedFeatures.has('tts')).toBe(true)

      // User signs out explicitly.
      useAuthStore.getState().clearSession()

      const s = useAuthStore.getState()
      expect(s.dismissedFeatures).toBeInstanceOf(Set)
      expect(s.dismissedFeatures.size).toBe(0)
      // Re-tapping a previously-dismissed feature should reopen the gate.
      useAuthStore.getState().openPremiumGate('tts')
      expect(useAuthStore.getState().premiumGateOpen).toBe(true)
    })

    // GAT-102 (#75) — the 401 forced sign-out path goes through
    // clearSession() (see lib/api.ts), so the same invariant must hold when
    // clearSession is invoked imperatively (as the 401 handler does).
    it('clearSession() (401 forced sign-out path) clears dismissedFeatures (#75)', () => {
      const { useAuthStore } = require('@/lib/stores/authStore')
      // Simulate the seeded "currently signed-in user with a dismissed gate"
      // state that the 401 handler would walk into.
      useAuthStore.setState({
        user: { id: 'u-pre-401', email: 'pre@example.com' },
        isAuthenticated: true,
        sessionToken: 'expired-token',
      })
      useAuthStore.getState().openPremiumGate('ai-chat')
      useAuthStore.getState().closePremiumGate()
      expect(useAuthStore.getState().dismissedFeatures.has('ai-chat')).toBe(true)

      // This is exactly what apps/mobile/lib/api.ts does after a 401:
      //   useAuthStore.getState().clearSession()
      useAuthStore.getState().clearSession()

      const s = useAuthStore.getState()
      expect(s.isAuthenticated).toBe(false)
      expect(s.user).toBeNull()
      expect(s.sessionToken).toBeNull()
      expect(s.dismissedFeatures.size).toBe(0)
    })
  })
})
