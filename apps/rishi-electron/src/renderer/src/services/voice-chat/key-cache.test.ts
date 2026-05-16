import { describe, it, expect, vi } from 'vitest'
import { createKeyCache } from './key-cache'
import type { ClockPort } from './types'

function makeClock(): ClockPort & { setNow(t: number): void } {
  let now = 0
  return {
    now: () => now,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (h) => clearTimeout(h),
    setNow: (t) => {
      now = t
    }
  }
}

describe('createKeyCache', () => {
  it('first get() calls fetch and returns its value', async () => {
    const clock = makeClock()
    const fetchFn = vi.fn().mockResolvedValue('K1')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 9 * 60 * 1000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('reuses the cached key within TTL', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValue('K1')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    await cache.get()
    clock.setNow(500)
    await cache.get()

    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('refetches after TTL expires', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValueOnce('K1').mockResolvedValueOnce('K2')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    clock.setNow(1001)
    await expect(cache.get()).resolves.toBe('K2')
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })

  it('concurrent get() calls share the same in-flight promise', async () => {
    const clock = makeClock()
    let resolveFetch!: (v: string) => void
    const fetchFn = vi.fn().mockImplementation(
      () =>
        new Promise<string>((r) => {
          resolveFetch = r
        })
    )
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 1000, clock })

    const p1 = cache.get()
    const p2 = cache.get()
    resolveFetch('K1')

    await expect(Promise.all([p1, p2])).resolves.toEqual(['K1', 'K1'])
    expect(fetchFn).toHaveBeenCalledTimes(1)
  })

  it('invalidate() forces the next get() to refetch', async () => {
    const clock = makeClock()
    clock.setNow(0)
    const fetchFn = vi.fn().mockResolvedValueOnce('K1').mockResolvedValueOnce('K2')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 60_000, clock })

    await expect(cache.get()).resolves.toBe('K1')
    cache.invalidate()
    await expect(cache.get()).resolves.toBe('K2')
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })

  it('invalidate() during an in-flight fetch discards that fetch result so the next get refetches', async () => {
    const clock = makeClock()
    let resolveFirst!: (v: string) => void
    const fetchFn = vi.fn()
      .mockImplementationOnce(() => new Promise<string>((r) => { resolveFirst = r }))
      .mockResolvedValueOnce('K2')
    const cache = createKeyCache({ fetch: fetchFn, ttlMs: 60_000, clock })

    // Start an in-flight fetch. Don't await it yet.
    const firstGet = cache.get()
    // Invalidate while the fetch is mid-flight.
    cache.invalidate()
    // Now resolve the original fetch — this stale result must NOT populate `cached`.
    resolveFirst('K1')
    await firstGet

    // Next get must refetch (not return the stale K1).
    await expect(cache.get()).resolves.toBe('K2')
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })
})
