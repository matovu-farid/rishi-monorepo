/**
 * GAT-107 (#79) — apiClient must not send both `Authorization: Bearer …`
 * AND `X-Dev-Bypass` on the same request.
 *
 * The worker treats `X-Dev-Bypass` as a "no auth required" escape hatch
 * for dev workflows. Sending it alongside a real bearer means signed-in
 * dev users never exercise the real premium gate (the bypass wins), and
 * any worker middleware that asserts one-or-the-other rejects the call.
 *
 * Contract: bearer XOR bypass. If a session token exists, the request
 * MUST NOT carry `X-Dev-Bypass`. Today the helper is invoked
 * unconditionally — this test pins the fix.
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

// Configure expo-constants so the dev-bypass helper has a real secret to
// emit. Without this the helper returns `{}` and the test would tautologically
// pass without exercising the guard.
jest.mock('expo-constants', () => ({
  __esModule: true,
  default: {
    expoConfig: {
      extra: { devBypassSecret: 'dev-secret-from-extra' },
    },
  },
}))

// Force __DEV__ on so `buildDevBypassHeaders` is willing to emit. The
// app's api.ts gates the helper on `__DEV__ === true`.
;(globalThis as { __DEV__?: boolean }).__DEV__ = true

const fetchMock = jest.fn()
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  fetchMock.mockReset()
})

function getHeaders(): Record<string, string> {
  // node-fetch / undici Response stores headers on the second arg of the
  // last fetch call. We read them straight from the mocked init object so
  // we can assert exact contents.
  const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
  return (init.headers ?? {}) as Record<string, string>
}

describe('apiClient — bearer XOR dev-bypass (#79 / GAT-107)', () => {
  it('sends Authorization bearer WITHOUT X-Dev-Bypass when signed in', async () => {
    secureStore.set('rishi.bearer', 'real-session-token')
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )

    const { apiClient } = require('@/lib/api')
    await apiClient('/api/premium')

    const headers = getHeaders()
    expect(headers.Authorization).toBe('Bearer real-session-token')
    // The header must NOT leak through when we already have a real token.
    // Sending both lets the worker's dev-bypass middleware short-circuit
    // the genuine premium check, so signed-in dev users never get to
    // exercise the real gate (GAT-107).
    expect(headers['X-Dev-Bypass']).toBeUndefined()
  })

  it('Authorization and X-Dev-Bypass are mutually exclusive (XOR property)', async () => {
    secureStore.set('rishi.bearer', 'real-session-token')
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )

    const { apiClient } = require('@/lib/api')
    await apiClient('/api/foo')

    const headers = getHeaders()
    const hasAuth = typeof headers.Authorization === 'string'
    const hasBypass = typeof headers['X-Dev-Bypass'] === 'string'
    // Logical XOR: exactly one of the two must be present.
    expect(hasAuth !== hasBypass).toBe(true)
  })
})
