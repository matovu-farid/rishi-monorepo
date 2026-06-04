/**
 * T-P2.3 — BILLING-002 mobile half: 402 interceptor in apiClient.
 *
 * Asserts that `apiClient` from `@/lib/api` runs the shared
 * `checkBillingGate` interceptor on every response and throws a typed
 * `BillingInactiveError` when the worker returns
 *   { status: 402, body: { code: 'BILLING_INACTIVE', subscriptionStatus } }
 * for any of the gated endpoints (audio/speech, embed, text/completions,
 * realtime/client_secrets).
 *
 * RED until:
 *   - `packages/shared/src/billing/interceptor.ts` + `errors.ts` exist
 *     (T-P1.3 lands them — see PLAN).
 *   - `apps/mobile/lib/api.ts` invokes `checkBillingGate(response)` before
 *     returning AND sets the mobile `billingStore` slice from the throw.
 *
 * NOTE: the body-shape and status checks are pinned to the SPEC §3.2
 * canonical reference (`workers/worker/src/billing/sub-gate.ts:57`).
 */

// ── secure-store + auth scaffolding so apiClient can build a request ─────
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

jest.mock('expo-crypto', () => ({}))
jest.mock('react-native-get-random-values', () => ({}), { virtual: true })

const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}

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

jest.mock('expo-constants', () => ({
  __esModule: true,
  default: { expoConfig: { extra: {} } },
}))

const fetchMock = jest.fn()
;(globalThis as { fetch: typeof fetch }).fetch = fetchMock as unknown as typeof fetch

beforeEach(() => {
  jest.resetModules()
  secureStore.clear()
  secureStore.set('rishi.bearer', 'good-token')
  fetchMock.mockReset()
})

/** Build a 402 BILLING_INACTIVE response per worker's `sub-gate.ts:57`. */
function billingInactive(subscriptionStatus: string | null): Response {
  return new Response(
    JSON.stringify({
      error: 'subscription required',
      code: 'BILLING_INACTIVE',
      subscriptionStatus,
    }),
    {
      status: 402,
      headers: { 'Content-Type': 'application/json' },
    },
  )
}

describe('BILLING-002 — apiClient 402 BILLING_INACTIVE interceptor', () => {
  it.each([
    '/api/text/completions',
    '/api/audio/speech',
    '/api/embed',
    '/api/realtime/client_secrets',
  ])('throws BillingInactiveError for 402 on %s', async (path) => {
    fetchMock.mockResolvedValueOnce(billingInactive('canceled'))

    const { apiClient } = require('@/lib/api')
    const { BillingInactiveError } = require('@rishi/shared/billing/errors')

    await expect(apiClient(path, { method: 'POST' })).rejects.toBeInstanceOf(
      BillingInactiveError,
    )
  })

  it('exposes the subscriptionStatus on the thrown error', async () => {
    fetchMock.mockResolvedValueOnce(billingInactive('unpaid'))

    const { apiClient } = require('@/lib/api')
    const { BillingInactiveError } = require('@rishi/shared/billing/errors')

    try {
      await apiClient('/api/text/completions', { method: 'POST' })
      throw new Error('expected apiClient to throw')
    } catch (err) {
      expect(err).toBeInstanceOf(BillingInactiveError)
      expect((err as { code: string }).code).toBe('BILLING_INACTIVE')
      expect(
        (err as { subscriptionStatus: string | null }).subscriptionStatus,
      ).toBe('unpaid')
    }
  })

  it('does NOT throw for a 200 response', async () => {
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )

    const { apiClient } = require('@/lib/api')
    const res = await apiClient('/api/text/completions', { method: 'POST' })
    expect(res.ok).toBe(true)
  })

  it('does NOT throw for a 402 whose body is NOT BILLING_INACTIVE', async () => {
    fetchMock.mockResolvedValueOnce(
      new Response(
        JSON.stringify({ error: 'some other 402 reason' }),
        {
          status: 402,
          headers: { 'Content-Type': 'application/json' },
        },
      ),
    )

    const { apiClient } = require('@/lib/api')
    const res = await apiClient('/api/text/completions', { method: 'POST' })
    expect(res.status).toBe(402)
    // Caller must still be able to read the body — `checkBillingGate`
    // clones the response on inspection (per shared interceptor spec).
    const body = await res.json()
    expect(body.error).toBe('some other 402 reason')
  })

  it('sets useBillingStore.billingInactive=true on 402 BILLING_INACTIVE', async () => {
    fetchMock.mockResolvedValueOnce(billingInactive('canceled'))

    const { apiClient } = require('@/lib/api')
    const { useBillingStore } = require('@/lib/stores/billingStore')

    await expect(
      apiClient('/api/audio/speech', { method: 'POST' }),
    ).rejects.toBeDefined()

    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(true)
    expect(s.subscriptionStatus).toBe('canceled')
  })
})
