/**
 * H1-04 — `authHydrated` must flip true on cold-start even when the user
 * is already signed in and lands on /(tabs) (skipping the /(auth) group).
 *
 * Before the fix the secure-store check lived inside `(auth)/_layout.tsx`,
 * which only mounts when expo-router matches an `/(auth)/*` route. A
 * RETURNING user (token in secure-store + user-id in MMKV) cold-starts
 * onto `/` which matches `/(tabs)/_layout.tsx`. That layout checks
 * `if (!authHydrated) return null` and renders nothing — but
 * `setAuthHydrated(true)` never fired because `(auth)/_layout.tsx` never
 * mounted. The user was stuck on a blank screen.
 *
 * This test pins the new contract: `hydrateAuth()` (called from the root
 * layout) completes the secure-store check itself, pushes the session
 * into the store when the bearer is valid, and flips `authHydrated: true`
 * unconditionally. It returns a promise so callers can `await` it.
 */

const mockGetSessionToken = jest.fn(async (): Promise<string | null> => null)
jest.mock('@/lib/auth', () => ({
  getSessionToken: () => mockGetSessionToken(),
}))

type StoreBackend = Map<string, string>
let backingStore: StoreBackend
function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (k: string, v: string) => {
      store.set(k, String(v))
    },
    getString: (k: string): string | undefined => store.get(k),
    remove: (k: string) => store.delete(k),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
  mockGetSessionToken.mockReset()
  mockGetSessionToken.mockResolvedValue(null)
})

describe('hydrateAuth completes the secure-store check (H1-04)', () => {
  it('flips authHydrated=true even when there is NO persisted session', async () => {
    const { useAuthStore } = require('@/lib/stores/authStore')
    await useAuthStore.getState().hydrateAuth()
    expect(useAuthStore.getState().authHydrated).toBe(true)
    expect(useAuthStore.getState().isAuthenticated).toBe(false)
    expect(useAuthStore.getState().user).toBeNull()
  })

  it('restores the session into the store when secure-store + MMKV both have data', async () => {
    mockGetSessionToken.mockResolvedValue('persisted-token')
    backingStore.set('rishi.mobile.auth:user-id', 'persisted-user-id')

    const { useAuthStore } = require('@/lib/stores/authStore')
    await useAuthStore.getState().hydrateAuth()

    const s = useAuthStore.getState()
    expect(s.authHydrated).toBe(true)
    expect(s.isAuthenticated).toBe(true)
    expect(s.user).toEqual({ id: 'persisted-user-id', email: null })
    expect(s.sessionToken).toBe('persisted-token')
  })

  it('does NOT mark isAuthenticated when only MMKV has data but secure-store is empty', async () => {
    // Token was wiped (e.g. by 401 handling) but MMKV user-id still hangs around.
    // The user must re-auth — we should NOT pretend they have a valid session.
    mockGetSessionToken.mockResolvedValue(null)
    backingStore.set('rishi.mobile.auth:user-id', 'orphan-user')

    const { useAuthStore } = require('@/lib/stores/authStore')
    await useAuthStore.getState().hydrateAuth()

    const s = useAuthStore.getState()
    expect(s.authHydrated).toBe(true)
    expect(s.isAuthenticated).toBe(false)
    // The user id is still surfaced so the UI can show "signed in as <id>"
    // briefly while the auth gate routes them to /(auth)/sign-in.
    expect(s.user?.id).toBe('orphan-user')
    expect(s.sessionToken).toBeNull()
  })

  it('still flips authHydrated=true when getSessionToken rejects', async () => {
    mockGetSessionToken.mockRejectedValueOnce(new Error('secure-store locked'))
    const { useAuthStore } = require('@/lib/stores/authStore')
    await useAuthStore.getState().hydrateAuth()
    // The route guard must un-block even if secure-store is unavailable —
    // we can't let a locked device permanently hang the UI.
    expect(useAuthStore.getState().authHydrated).toBe(true)
    expect(useAuthStore.getState().isAuthenticated).toBe(false)
  })
})
