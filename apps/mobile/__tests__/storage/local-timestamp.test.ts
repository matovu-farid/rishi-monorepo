/**
 * DAT-015 (#127) — within-device monotonic tiebreaker for sync timestamps.
 *
 * The sync engine's conflict resolution (in lib/sync/drizzle-adapter.ts) uses
 * `if (remoteUpdatedAt < localUpdatedAt) return` — i.e. equal timestamps fall
 * through and the remote wins. When the same device produces two writes in
 * the same JavaScript millisecond (UI rapid taps, debounced commits, RAG
 * answer + auto-title hitting Date.now() back-to-back), they collide and
 * one of them is overwritten on the next sync round-trip.
 *
 * `nextLocalTimestamp()` returns a strictly-monotonic value so consecutive
 * writes are always orderable. It is NOT a globally unique revision id —
 * cross-device ties still depend on a server-side tiebreaker — but it
 * removes the within-device portion of the failure mode.
 */

// expo-sqlite ships ESM; stub before db.ts touches it.
jest.mock('expo-sqlite', () => ({
  openDatabaseSync: jest.fn(() => ({
    execSync: jest.fn(),
    getAllSync: jest.fn(() => []),
    getFirstSync: jest.fn(() => undefined),
  })),
}))

jest.mock('drizzle-orm/expo-sqlite', () => ({
  drizzle: jest.fn(() => ({})),
}))

jest.mock('@rishi/shared/schema', () => ({
  books: {},
  highlights: {},
  bookmarks: {},
  conversations: {},
  messages: {},
  syncMeta: {},
  syncState: {},
}))

import { nextLocalTimestamp } from '@/lib/db'

describe('nextLocalTimestamp', () => {
  it('returns Date.now() when the clock has advanced', () => {
    const before = Date.now()
    const t = nextLocalTimestamp()
    const after = Date.now()
    expect(t).toBeGreaterThanOrEqual(before)
    // The returned timestamp must be no further in the future than 1 ms
    // past `Date.now()` at the time the function returned.
    expect(t).toBeLessThanOrEqual(after + 1)
  })

  it('is strictly monotonic across two back-to-back calls', () => {
    const a = nextLocalTimestamp()
    const b = nextLocalTimestamp()
    expect(b).toBeGreaterThan(a)
  })

  it('is strictly monotonic across many rapid calls in the same ms', () => {
    const stamps: number[] = []
    for (let i = 0; i < 50; i++) stamps.push(nextLocalTimestamp())
    for (let i = 1; i < stamps.length; i++) {
      expect(stamps[i]).toBeGreaterThan(stamps[i - 1])
    }
  })

  it('catches up to wall-clock after a long pause', () => {
    nextLocalTimestamp()
    // Simulate a long pause — the wall clock is now well ahead of our
    // internal counter; the next call must return a wall-clock value,
    // not the counter+1.
    const future = Date.now() + 5_000
    const realDateNow = Date.now
    try {
      Date.now = () => future
      const t = nextLocalTimestamp()
      expect(t).toBeGreaterThanOrEqual(future)
      // And we don't leap further than 1ms past the wall clock.
      expect(t).toBeLessThanOrEqual(future + 1)
    } finally {
      Date.now = realDateNow
    }
  })
})
