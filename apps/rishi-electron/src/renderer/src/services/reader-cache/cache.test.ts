import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createReaderCache, type ReaderCache } from './cache'

interface FakeDoc {
  id: string
}

function makeBytes(size: number): Uint8Array {
  return new Uint8Array(size)
}

let destroy: ReturnType<typeof vi.fn<(doc: FakeDoc) => void>>
let cache: ReaderCache<FakeDoc>

beforeEach(() => {
  destroy = vi.fn<(doc: FakeDoc) => void>()
  cache = createReaderCache<FakeDoc>({
    name: 'test',
    maxEntries: 3,
    maxEntryBytes: 1_000,
    maxTotalBytes: 2_000,
    destroy
  })
})

describe('createReaderCache — get/set/evict basics', () => {
  it('returns undefined on miss', () => {
    expect(cache.get(1)).toBeUndefined()
  })

  it('round-trips a stored entry', () => {
    const doc = { id: 'a' }
    const bytes = makeBytes(100)
    cache.set(1, doc, bytes)

    const entry = cache.get(1)
    expect(entry?.document).toBe(doc)
    expect(entry?.bytes).toBe(bytes)
    expect(entry?.size).toBe(100)
  })

  it('refreshes lastAccess on get', async () => {
    cache.set(1, { id: 'a' }, makeBytes(100))
    const first = cache.get(1)!.lastAccess
    // Busy-wait a tick so Date.now() advances even on fast hardware.
    await new Promise((r) => {
      setTimeout(r, 5)
    })
    const second = cache.get(1)!.lastAccess
    expect(second).toBeGreaterThan(first)
  })

  it('evict destroys the cached document', () => {
    const doc = { id: 'a' }
    cache.set(1, doc, makeBytes(100))
    cache.evict(1)
    expect(destroy).toHaveBeenCalledWith(doc)
    expect(cache.get(1)).toBeUndefined()
  })

  it('evict is a no-op for unknown ids', () => {
    cache.evict(99)
    expect(destroy).not.toHaveBeenCalled()
  })
})

describe('createReaderCache — LRU by entry count', () => {
  it('evicts the least-recently-used entry when maxEntries exceeded', async () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const c = { id: 'c' }
    const d = { id: 'd' }
    cache.set(1, a, makeBytes(10))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    cache.set(2, b, makeBytes(10))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    cache.set(3, c, makeBytes(10))
    await new Promise((r) => {
      setTimeout(r, 2)
    })

    // Touch #1 so #2 becomes the LRU.
    cache.get(1)
    await new Promise((r) => {
      setTimeout(r, 2)
    })

    cache.set(4, d, makeBytes(10))

    expect(cache.get(1)?.document).toBe(a)
    expect(cache.get(2)).toBeUndefined()
    expect(cache.get(3)?.document).toBe(c)
    expect(cache.get(4)?.document).toBe(d)
    expect(destroy).toHaveBeenCalledWith(b)
    expect(destroy).toHaveBeenCalledTimes(1)
  })
})

describe('createReaderCache — replace in place', () => {
  it('destroys the old document when replacing under the same id', () => {
    const oldDoc = { id: 'old' }
    const newDoc = { id: 'new' }
    cache.set(1, oldDoc, makeBytes(50))
    cache.set(1, newDoc, makeBytes(75))

    expect(destroy).toHaveBeenCalledWith(oldDoc)
    expect(destroy).not.toHaveBeenCalledWith(newDoc)
    const entry = cache.get(1)
    expect(entry?.document).toBe(newDoc)
    expect(entry?.size).toBe(75)
  })

  it('no-ops when re-setting the exact same document', () => {
    const doc = { id: 'a' }
    cache.set(1, doc, makeBytes(100))
    cache.set(1, doc, makeBytes(100))
    expect(destroy).not.toHaveBeenCalled()
  })
})

describe('createReaderCache — per-entry size cap', () => {
  it('skips caching documents above maxEntryBytes', () => {
    const huge = { id: 'huge' }
    cache.set(1, huge, makeBytes(1_500)) // > 1_000 cap
    expect(cache.get(1)).toBeUndefined()
    // Caller keeps ownership — cache must not destroy what it refused.
    expect(destroy).not.toHaveBeenCalled()
  })

  it('drops a stale entry when the replacement exceeds the per-entry cap', () => {
    const small = { id: 'small' }
    const huge = { id: 'huge' }
    cache.set(1, small, makeBytes(100))
    cache.set(1, huge, makeBytes(1_500))

    // Small entry destroyed, huge entry refused.
    expect(destroy).toHaveBeenCalledWith(small)
    expect(destroy).not.toHaveBeenCalledWith(huge)
    expect(cache.get(1)).toBeUndefined()
  })
})

describe('createReaderCache — total-byte budget', () => {
  it('evicts older entries to stay under maxTotalBytes', async () => {
    const a = { id: 'a' }
    const b = { id: 'b' }
    const c = { id: 'c' }
    cache.set(1, a, makeBytes(900))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    cache.set(2, b, makeBytes(900))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    // Total now 1800/2000. Adding 900 → 2700, must evict to fit.
    cache.set(3, c, makeBytes(900))

    expect(cache.get(1)).toBeUndefined()
    expect(cache.get(2)?.document).toBe(b)
    expect(cache.get(3)?.document).toBe(c)
    expect(destroy).toHaveBeenCalledWith(a)
  })

  it('never evicts the just-inserted entry, even at the budget edge', () => {
    // Single insert at the cap should survive even if it pushes others
    // out — but with an empty cache, just-inserted is the only entry.
    const a = { id: 'a' }
    cache.set(1, a, makeBytes(1_000))
    expect(cache.get(1)?.document).toBe(a)
  })
})

describe('createReaderCache — interaction', () => {
  it('count cap and byte cap compose without double-destroying', async () => {
    const docs = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }]
    cache.set(1, docs[0], makeBytes(600))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    cache.set(2, docs[1], makeBytes(600))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    cache.set(3, docs[2], makeBytes(600))
    await new Promise((r) => {
      setTimeout(r, 2)
    })
    // Total 1800/2000, count 3/3. Adding a 4th 600B entry exceeds
    // both budgets — evict exactly one (the oldest), not two.
    cache.set(4, docs[3], makeBytes(600))

    expect(destroy).toHaveBeenCalledTimes(1)
    expect(destroy).toHaveBeenCalledWith(docs[0])
    expect(cache.get(1)).toBeUndefined()
    expect(cache.get(2)?.document).toBe(docs[1])
    expect(cache.get(3)?.document).toBe(docs[2])
    expect(cache.get(4)?.document).toBe(docs[3])
  })
})
