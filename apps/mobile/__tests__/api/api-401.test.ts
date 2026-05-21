/**
 * H1-03 — apiClient 401 handling must sync the authStore.
 *
 * Today's `apiClient` clears the `rishi.bearer` key in expo-secure-store
 * when the worker returns 401, but never tells the in-memory authStore.
 * The result: `useAuthStore.getState().isAuthenticated` stays `true` and
 * the UI keeps treating the user as signed in even though every
 * subsequent request will fail with "no session token".
 *
 * The fix lazily imports authStore from `apiClient` so we don't pull
 * Zustand into modules that don't need it. The test pins the contract:
 * after a 401, authStore is cleared atomically alongside secure-store.
 */

// ── Mocks (declared before SUT import) ───────────────────────────────────────
const secureStore = new Map<string, string>()
jest.mock('expo-secure-store', () => ({
  getItemAsync: jest.fn(async (key: string) => secureStore.get(key) ?? null),
  setItemAsync: jest.fn(async (key: string, value: string) => {
    secureStore.set(key, value)
  }),
  deleteItemAsync: jest.fn(async (key: string) => {
    secureStore.delete(key)
  }),
}))

jest.mock('expo-web-browser', () => ({
  openAuthSessionAsync: jest.fn(),
  maybeCompleteAuthSession: jest.fn(),
}))

const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}
jest.mock('expo-crypto', () => ({}))
jest.mock('react-native-get-random-values', () => ({}), { virtual: true })

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const s = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        s.set(k, v)
      },
      getString: (k: string): string | undefined => s.get(k),
      remove: (k: string) => s.delete(k),
      getAllKeys: () => Array.from(s.keys()),
      clearAll: () => s.clear(),
    }
  },
}))

jest.mock('expo-constants', () => ({
  __esModule: true,
  default: { expoConfig: { extra: {} } },
}))

const fetchMock = jest.fn()
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  fetchMock.mockReset()
})

describe('apiClient 401 handling (H1-03)', () => {
  it('clears secure-store on 401 (baseline)', async () => {
    secureStore.set('rishi.bearer', 'expired-token')
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 }),
    )
    const { apiClient } = require('@/lib/api')
    await expect(apiClient('/api/foo')).rejects.toThrow(/session expired/i)
    expect(secureStore.get('rishi.bearer')).toBeUndefined()
  })

  it('clears the in-memory authStore on 401 (H1-03)', async () => {
    secureStore.set('rishi.bearer', 'expired-token')
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 }),
    )

    // Seed the authStore as if the user were currently signed in.
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      isAuthenticated: true,
      sessionToken: 'expired-token',
    })

    const { apiClient } = require('@/lib/api')
    await expect(apiClient('/api/foo')).rejects.toThrow(/session expired/i)

    // The in-memory store must reflect the signed-out state, otherwise
    // the UI keeps treating the user as signed in until the next manual
    // hydrateAuth call.
    const s = useAuthStore.getState()
    expect(s.isAuthenticated).toBe(false)
    expect(s.user).toBeNull()
    expect(s.sessionToken).toBeNull()
  })

  it('does NOT touch authStore on a 2xx response', async () => {
    secureStore.set('rishi.bearer', 'good-token')
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )

    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      isAuthenticated: true,
      sessionToken: 'good-token',
    })

    const { apiClient } = require('@/lib/api')
    const res = await apiClient('/api/foo')
    expect(res.ok).toBe(true)

    // Sanity: store is untouched.
    const s = useAuthStore.getState()
    expect(s.isAuthenticated).toBe(true)
    expect(s.user).toEqual({ id: 'u1', email: 'a@b.com' })
  })
})
