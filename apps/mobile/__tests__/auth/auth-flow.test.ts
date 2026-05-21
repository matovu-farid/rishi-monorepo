/**
 * Tests for the mobile Better-Auth deep-link flow.
 *
 * `lib/auth.ts` is the orchestrator:
 *   1. signIn(provider)
 *      - calls @rishi/shared startAuthSession() against the worker
 *      - opens an in-app browser via expo-web-browser.openAuthSessionAsync
 *      - on dismissal/return, parses the `state` from the result URL and
 *        calls completeAuthSession() → receives { session_token, user_id }
 *      - persists session_token to expo-secure-store under `rishi.bearer`
 *      - returns the token
 *   2. signOut()
 *      - clears the secure-store key
 *   3. getSessionToken() / isAuthenticated() — read the cached token
 *
 * We mock expo-web-browser, expo-secure-store, expo-crypto (random bytes),
 * and `fetch` so the tests exercise the wiring without any real network.
 */

// ── Mocks (declared before the SUT import) ────────────────────────────────────
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

let lastBrowserUrl: string | null = null
let browserResult:
  | { type: 'success'; url: string }
  | { type: 'cancel' }
  | { type: 'dismiss' }
  | { type: 'locked' } = { type: 'cancel' }

jest.mock('expo-web-browser', () => ({
  openAuthSessionAsync: jest.fn(async (url: string, _redirect: string) => {
    lastBrowserUrl = url
    return browserResult
  }),
  maybeCompleteAuthSession: jest.fn(),
  WebBrowserPresentationStyle: { PAGE_SHEET: 'pageSheet' },
}))

// Polyfill crypto for Node 18+ (Node 20+ has it globally — keep this defensive).
const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}

// expo-crypto polyfill no-op in tests (real crypto already present).
jest.mock('expo-crypto', () => ({
  // expo-crypto is imported for its side effect (polyfilling
  // crypto.getRandomValues on RN). In Node the global already exists,
  // so the import is a no-op.
}))

// react-native-get-random-values polyfill (in case auth.ts imports it).
jest.mock('react-native-get-random-values', () => ({}), { virtual: true })

// Stub other native modules the storage path might pull in.
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const store = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        store.set(k, v)
      },
      getString: (k: string): string | undefined => store.get(k),
      remove: (k: string) => store.delete(k),
      getAllKeys: () => Array.from(store.keys()),
      clearAll: () => store.clear(),
    }
  },
}))

// ── fetch mock ───────────────────────────────────────────────────────────────
type FetchCall = [string, RequestInit | undefined]
const fetchCalls: FetchCall[] = []
let mobileStartResponse: () => Response = () =>
  new Response(
    JSON.stringify({
      state: 'state-abc',
      authUrl: 'https://web.example.com/sign-in?state=state-abc',
    }),
    { status: 200 },
  )
let mobileVerifyResponse: () => Response = () =>
  new Response(JSON.stringify({ session_token: 'token-xyz', user_id: 'user-1' }), { status: 200 })

const fetchMock = jest.fn(async (url: string, init?: RequestInit) => {
  fetchCalls.push([url, init])
  if (url.endsWith('/mobile/start')) return mobileStartResponse()
  if (url.endsWith('/mobile/start/verify')) return mobileVerifyResponse()
  return new Response('not found', { status: 404 })
})
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

// ── reset between tests ──────────────────────────────────────────────────────
beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  fetchCalls.length = 0
  fetchMock.mockClear()
  lastBrowserUrl = null
  browserResult = {
    type: 'success',
    url: 'rishimobile://auth/callback?state=state-abc',
  }
  mobileStartResponse = () =>
    new Response(
      JSON.stringify({
        state: 'state-abc',
        authUrl: 'https://web.example.com/sign-in?state=state-abc',
      }),
      { status: 200 },
    )
  mobileVerifyResponse = () =>
    new Response(JSON.stringify({ session_token: 'token-xyz', user_id: 'user-1' }), {
      status: 200,
    })
})

describe('mobile auth flow (lib/auth.ts)', () => {
  it('signIn() POSTs to /mobile/start, opens the returned authUrl, and stores the verified token', async () => {
    const auth = require('@/lib/auth')
    const result = await auth.signIn('google')

    // Two HTTP calls: /mobile/start, then /mobile/start/verify
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchCalls[0][0]).toMatch(/\/mobile\/start$/)
    expect(fetchCalls[1][0]).toMatch(/\/mobile\/start\/verify$/)

    // The browser was opened with the URL returned by /mobile/start.
    expect(lastBrowserUrl).toBe('https://web.example.com/sign-in?state=state-abc')

    // Token was persisted under the canonical mobile bearer key.
    expect(secureStore.get('rishi.bearer')).toBe('token-xyz')

    // signIn returns the token + user id for the caller to react to.
    expect(result).toEqual({ session_token: 'token-xyz', user_id: 'user-1' })
  })

  it('signIn() defaults to provider="google" when omitted', async () => {
    const auth = require('@/lib/auth')
    await auth.signIn()

    const startBody = JSON.parse(fetchCalls[0][1]?.body as string)
    expect(startBody.provider).toBe('google')
  })

  it('signIn() sends the chosen provider', async () => {
    const auth = require('@/lib/auth')
    await auth.signIn('password')
    const startBody = JSON.parse(fetchCalls[0][1]?.body as string)
    expect(startBody.provider).toBe('password')
  })

  it('signIn() throws when the user cancels the browser', async () => {
    browserResult = { type: 'cancel' }
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow(/cancel|dismiss/i)

    // No /verify call because we never got a callback URL.
    expect(fetchCalls.length).toBe(1)
    expect(secureStore.get('rishi.bearer')).toBeUndefined()
  })

  it('signIn() throws when the callback URL is missing a state', async () => {
    browserResult = { type: 'success', url: 'rishimobile://auth/callback' }
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow(/state/i)
  })

  it('signIn() throws and clears any partial state on /verify failure', async () => {
    mobileVerifyResponse = () =>
      new Response(JSON.stringify({ error: 'pkce_mismatch' }), { status: 403 })
    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow(/pkce|403/i)
    expect(secureStore.get('rishi.bearer')).toBeUndefined()
  })

  it('signOut() removes the cached bearer token', async () => {
    const auth = require('@/lib/auth')
    await auth.signIn('google')
    expect(secureStore.get('rishi.bearer')).toBe('token-xyz')

    await auth.signOut()
    expect(secureStore.get('rishi.bearer')).toBeUndefined()
  })

  it('getSessionToken() returns the cached token, or null when not signed in', async () => {
    const auth = require('@/lib/auth')
    expect(await auth.getSessionToken()).toBeNull()
    await auth.signIn('google')
    expect(await auth.getSessionToken()).toBe('token-xyz')
  })

  it('isAuthenticated() reflects the presence of a cached token', async () => {
    const auth = require('@/lib/auth')
    expect(await auth.isAuthenticated()).toBe(false)
    await auth.signIn('google')
    expect(await auth.isAuthenticated()).toBe(true)
    await auth.signOut()
    expect(await auth.isAuthenticated()).toBe(false)
  })
})
