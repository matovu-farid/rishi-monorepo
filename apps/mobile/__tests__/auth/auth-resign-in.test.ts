/**
 * CG10 — `signIn()` while a bearer token is already cached.
 *
 * Today's `lib/auth.signIn()` is unconditional: it always runs the full
 * /mobile/start → browser → /verify pipeline and overwrites whatever
 * token is in secure-store. There's no "you're already signed in"
 * short-circuit, no error, no token preservation.
 *
 * These tests pin that contract so a future refactor doesn't silently
 * change behavior (e.g., to reject when already signed-in, which would
 * break the re-auth-on-token-expiry flow apiClient relies on).
 *
 * This test lives in its own file to avoid contention with Phase A,
 * which is concurrently editing `auth-flow.test.ts`.
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

let browserResult:
  | { type: 'success'; url: string }
  | { type: 'cancel' }
  | { type: 'dismiss' }
  | { type: 'locked' } = {
  type: 'success',
  url: 'rishimobile://auth/callback?state=state-second',
}

jest.mock('expo-web-browser', () => ({
  openAuthSessionAsync: jest.fn(async () => browserResult),
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
    const s = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        s.set(k, String(v))
      },
      getString: (k: string): string | undefined => s.get(k),
      remove: (k: string) => s.delete(k),
      getAllKeys: () => Array.from(s.keys()),
      clearAll: () => s.clear(),
    }
  },
}))

const fetchMock = jest.fn(async (url: string) => {
  if (url.endsWith('/mobile/start')) {
    return new Response(
      JSON.stringify({
        state: 'state-second',
        authUrl: 'https://web.example.com/sign-in?state=state-second',
      }),
      { status: 200 },
    )
  }
  if (url.endsWith('/mobile/start/verify')) {
    return new Response(
      JSON.stringify({ session_token: 'token-second', user_id: 'user-2' }),
      { status: 200 },
    )
  }
  return new Response('not found', { status: 404 })
})
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  fetchMock.mockClear()
  browserResult = {
    type: 'success',
    url: 'rishimobile://auth/callback?state=state-second',
  }
})

describe('signIn() called while already signed-in (CG10)', () => {
  it('overwrites the existing bearer token with the newly-minted one', async () => {
    // Pretend a prior session left a stale token in secure-store.
    secureStore.set('rishi.bearer', 'old-token-from-previous-session')

    const auth = require('@/lib/auth')
    expect(await auth.getSessionToken()).toBe('old-token-from-previous-session')

    const result = await auth.signIn('google')
    expect(result.session_token).toBe('token-second')
    // The new token replaces the old one — no "already signed in" short-circuit.
    expect(secureStore.get('rishi.bearer')).toBe('token-second')
  })

  it('runs the full /mobile/start → /verify pipeline a second time (no short-circuit)', async () => {
    secureStore.set('rishi.bearer', 'old-token')

    const auth = require('@/lib/auth')
    await auth.signIn('google')

    // Two HTTP calls — exactly the same as a cold sign-in.
    expect(fetchMock).toHaveBeenCalledTimes(2)
    const calls = fetchMock.mock.calls.map(([url]) => url as string)
    expect(calls.some((u) => u.endsWith('/mobile/start'))).toBe(true)
    expect(calls.some((u) => u.endsWith('/mobile/start/verify'))).toBe(true)
  })

  it('on failed re-signIn (cancel) the OLD token is preserved (NOT cleared on failure)', async () => {
    // This is important: a user who cancels a re-auth attempt must
    // still have their prior session intact. apiClient relies on this
    // when surfacing a "re-auth needed" prompt that the user dismisses.
    secureStore.set('rishi.bearer', 'old-token')
    browserResult = { type: 'cancel' }

    const auth = require('@/lib/auth')
    await expect(auth.signIn('google')).rejects.toThrow(/cancel|dismiss/i)

    // The old token survived the cancelled re-auth.
    expect(secureStore.get('rishi.bearer')).toBe('old-token')
  })
})
