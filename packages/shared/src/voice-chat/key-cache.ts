import type { ClockPort } from './types'

/**
 * 9-minute ephemeral-key cache. Verbatim port from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/key-cache.ts`.
 * Tests are also ported verbatim.
 */
export interface KeyCache {
  /**
   * Returns the cached key if within TTL, otherwise fetches a new one.
   * Concurrent callers share the in-flight promise.
   */
  get(): Promise<string>
  /**
   * Drop any cached key so the next `get()` refetches. Used when a setting
   * that affects the minted key (e.g., language) changes.
   */
  invalidate(): void
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
  // Bumped on invalidate(). Each in-flight fetch captures the current value
  // when it starts; if the generation has moved on by the time it resolves,
  // it discards its result rather than overwriting `cached` with a stale key.
  let generation = 0

  return {
    async get() {
      if (cached && clock.now() - cached.fetchedAt < ttlMs) {
        return cached.key
      }
      if (inflight) return inflight

      const myGeneration = generation
      inflight = (async () => {
        try {
          const key = await fetch()
          if (myGeneration === generation) {
            cached = { key, fetchedAt: clock.now() }
          }
          return key
        } finally {
          if (myGeneration === generation) {
            inflight = null
          }
        }
      })()

      return inflight
    },
    invalidate() {
      cached = null
      inflight = null
      generation++
    }
  }
}
