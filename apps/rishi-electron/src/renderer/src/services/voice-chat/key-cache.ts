import type { ClockPort } from './types'

export interface KeyCache {
  /**
   * Returns the cached key if within TTL, otherwise fetches a new one.
   * Concurrent callers share the in-flight promise.
   */
  get(): Promise<string>
}

export interface KeyCacheDeps {
  fetch: () => Promise<string>
  ttlMs: number
  clock: ClockPort
}

/**
 * Stage 2 fallback implementation.
 *
 * Initial Stage 2 attempt swapped internals to `Cache.make` from Effect,
 * which uses the real wall clock for TTL. The existing test injects a fake
 * clock and advances it past the TTL via `clock.setNow(1001)`; under
 * `Cache.make`, no real time elapsed so the cached entry was returned and
 * the TTL-expiry test failed. Per the plan's documented decision rule we
 * retain the Stage 1 manual implementation (byte-for-byte) so the public
 * contract — and the four existing test cases — pass unchanged. The "small
 * win" of replacing this with `Cache.make` is deferred.
 */
export function createKeyCache(deps: KeyCacheDeps): KeyCache {
  const { fetch, ttlMs, clock } = deps
  let cached: { key: string; fetchedAt: number } | null = null
  let inflight: Promise<string> | null = null

  return {
    async get() {
      if (cached && clock.now() - cached.fetchedAt < ttlMs) {
        return cached.key
      }
      if (inflight) return inflight

      inflight = (async () => {
        try {
          const key = await fetch()
          cached = { key, fetchedAt: clock.now() }
          return key
        } finally {
          inflight = null
        }
      })()

      return inflight
    }
  }
}
