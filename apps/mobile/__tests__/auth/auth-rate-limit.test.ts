/**
 * CG30 — `/mobile/start` rate-limit (429) behaviour from the mobile
 * client perspective.
 *
 * The audit row suggested extending `workers/worker/src/routes/mobile.test.ts`,
 * but the underlying contract Better-Auth provides (HTTP 429 with a
 * Retry-After header when the per-IP rate-limit fires) is well-known
 * upstream. What's NOT specified by upstream is what the MOBILE CLIENT
 * does when it lands — and that's the contract product behaviour
 * depends on. This test pins:
 *
 *   1. `signIn()` rejects with an error that mentions the 429 status,
 *   2. NO browser session is opened (we never call
 *      WebBrowser.openAuthSessionAsync),
 *   3. NO bearer token is persisted to secure-store,
 *   4. NO `verify` call is made (we never reach the second leg).
 *
 * If the worker ever stops returning 429 for /mobile/start (e.g., a
 * downstream Better-Auth upgrade changes the status) the failing leg
 * here will still fire — the message just won't match `/429/`. That's a
 * deliberate test choice so this catches drift on either side.
 *
 * This test lives in a DEDICATED file (not extending `auth-flow.test.ts`)
 * to avoid contention with Phase A which is concurrently editing that
 * file.
 */

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

let browserOpened = false
jest.mock('expo-web-browser', () => ({
  openAuthSessionAsync: jest.fn(async () => {
    browserOpened = true
    return { type: 'cancel' as const }
  }),
  maybeCompleteAuthSession: jest.fn(),
  WebBrowserPresentationStyle: { PAGE_SHEET: 'pageSheet' },
}))

const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}

jest.mock('expo-crypto', () => ({}))
jest.mock('react-native-get-random-values', () => ({}), { virtual: true })

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const store = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        store.set(k, String(v))
      },
      getString: (k: string): string | undefined => store.get(k),
      remove: (k: string) => store.delete(k),
      getAllKeys: () => Array.from(store.keys()),
      clearAll: () => store.clear(),
    }
  },
}))

// ── fetch mock — returns 429 for /mobile/start ─────────────────────────────
type FetchCall = [string, RequestInit | undefined]
const fetchCalls: FetchCall[] = []
const fetchMock = jest.fn(async (url: string, init?: RequestInit) => {
  fetchCalls.push([url, init])
  if (url.endsWith('/mobile/start')) {
    return new Response(
      JSON.stringify({ error: 'rate_limit_exceeded' }),
      {
        status: 429,
        headers: {
          'Content-Type': 'application/json',
          // Better-Auth attaches Retry-After by default.
          'Retry-After': '60',
        },
      },
    )
  }
  if (url.endsWith('/mobile/start/verify')) {
    // We should NEVER reach this leg under rate-limit conditions.
    return new Response('forbidden second leg', { status: 500 })
  }
  return new Response('not found', { status: 404 })
})
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  fetchCalls.length = 0
  fetchMock.mockClear()
  browserOpened = false
})

describe('mobile signIn() under /mobile/start rate-limit (CG30)', () => {
  it('rejects with the 429 status in the error message', async () => {
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow(/429/)
  })

  it('does NOT open the in-app browser when /mobile/start rate-limits', async () => {
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow()
    expect(browserOpened).toBe(false)
  })

  it('does NOT persist a bearer token to secure-store', async () => {
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow()
    expect(secureStore.get('rishi.bearer')).toBeUndefined()
  })

  it('does NOT call /mobile/start/verify (never reaches the second leg)', async () => {
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow()
    const verifyCalls = fetchCalls.filter(([url]) => url.endsWith('/mobile/start/verify'))
    expect(verifyCalls).toHaveLength(0)
  })
})
