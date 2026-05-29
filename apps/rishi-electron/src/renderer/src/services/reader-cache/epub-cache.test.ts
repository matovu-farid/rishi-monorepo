import { describe, it, expect } from 'vitest'
import type { Book } from 'epubjs'
import { getCachedEpub, setCachedEpub, evictEpub } from './epub-cache'

function makeBook(id: string): Book {
  // Only `destroy` is invoked by the cache. The real epubjs Book is much
  // heavier; an opaque shape is enough for cache-level tests.
  return { id, destroy: () => undefined } as unknown as Book
}

describe('epub-cache — version-aware lookup', () => {
  it('returns a miss when the requested version differs from the cached version', () => {
    const bookId = 9002
    setCachedEpub(bookId, makeBook('v1'), new Uint8Array(10), 1)

    const hit = getCachedEpub(bookId, 1)
    expect(hit?.document).toBeDefined()

    const stale = getCachedEpub(bookId, 2)
    expect(stale).toBeUndefined()

    evictEpub(bookId)
  })
})
