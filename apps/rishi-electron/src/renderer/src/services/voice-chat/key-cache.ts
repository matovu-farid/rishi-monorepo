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
