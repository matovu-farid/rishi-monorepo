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
})
