/**
 * N01 — X-Dev-Bypass header on mobile's apiClient.
 *
 * Electron's `lib/api.ts` injects `X-Dev-Bypass: <secret>` when
 * `getAuthHeaders()` returns no bearer (so dev workflows can skip the
 * premium-feature paywall). Mobile must do the same when __DEV__ and a
 * `DEV_BYPASS_SECRET` (via expo extra / env) is set.
 *
 * We exercise the pure `buildDevBypassHeaders` helper rather than the
 * fetch wrapper itself, since the wrapper requires a session token to
 * even attempt the call (and __DEV__ is a Metro-defined global).
 */

jest.mock('expo-constants', () => ({
  __esModule: true,
  default: {
    expoConfig: { extra: {} },
  },
}))

import { buildDevBypassHeaders, readDevBypassSecret } from '@/lib/api-dev-bypass'

describe('buildDevBypassHeaders', () => {
  it('returns an empty object when not in __DEV__', () => {
    expect(buildDevBypassHeaders({ isDev: false, secret: 'abc' })).toEqual({})
  })

  it('returns an empty object when secret is null', () => {
    expect(buildDevBypassHeaders({ isDev: true, secret: null })).toEqual({})
  })

  it('returns an empty object when secret is empty string', () => {
    expect(buildDevBypassHeaders({ isDev: true, secret: '' })).toEqual({})
  })

  it('returns X-Dev-Bypass header when __DEV__ and secret is set', () => {
    expect(buildDevBypassHeaders({ isDev: true, secret: 'dev-secret-123' })).toEqual({
      'X-Dev-Bypass': 'dev-secret-123',
    })
  })

  it('does not include the header in production even with a secret', () => {
    expect(buildDevBypassHeaders({ isDev: false, secret: 'leaked-secret' })).toEqual({})
  })
})

describe('readDevBypassSecret', () => {
  const originalEnv = process.env.DEV_BYPASS_SECRET

  afterEach(() => {
    if (originalEnv === undefined) {
      delete process.env.DEV_BYPASS_SECRET
    } else {
      process.env.DEV_BYPASS_SECRET = originalEnv
    }
  })

  it('falls back to process.env.DEV_BYPASS_SECRET when expoConfig.extra is empty', () => {
    process.env.DEV_BYPASS_SECRET = 'env-secret'
    expect(readDevBypassSecret()).toBe('env-secret')
  })

  it('returns null when neither expo extra nor env is set', () => {
    delete process.env.DEV_BYPASS_SECRET
    expect(readDevBypassSecret()).toBeNull()
  })
})
