import type { Book } from 'epubjs'
import { createReaderCache } from './cache'

// Warm-restore cache for parsed EPUB Books. Reopening a recently-viewed
// book skips epub.js's container.xml / content.opf / nav parse and goes
// straight to attaching a new rendition.
//
// Inner EpubView reads via getCachedEpub on mount; on cache hit it
// reuses the cached Book and skips book.destroy() on unmount. The cache
// owns destroy — triggered by LRU eviction, byte-budget pressure, or
// explicit evictEpub (called from delete flows).
//
// Note: epub.js binds a single rendition to each Book (book.rendition =
// ...). Only the visible reader uses the cache. The hidden paragraph
// reader needs its own throwaway Book — sharing would have it clobber
// the visible reader's rendition.

const epubCache = createReaderCache<Book>({
  name: 'epub',
  maxEntries: 3,
  maxEntryBytes: 50_000_000,
  maxTotalBytes: 150_000_000,
  destroy: (book) => book.destroy()
})

// `version` is book.version from the DB row. Pass it through so a
// re-imported file with the same bookId but a bumped version doesn't get
// the stale parsed epubjs Book. Callers that genuinely don't have a
// version (legacy code paths) can omit it — the cache then ignores
// versioning.
export const getCachedEpub = (bookId: number, version?: number) => epubCache.get(bookId, version)
export const setCachedEpub = (
  bookId: number,
  book: Book,
  bytes: Uint8Array,
  version?: number
): void => epubCache.set(bookId, book, bytes, version)
export const evictEpub = (bookId: number): void => epubCache.evict(bookId)

// Diagnostic handle for e2e tests. Keeping it as a getter object (no
// `.set`/`.evict` exposed) means a misbehaving test can't corrupt
// real cache state.
if (typeof window !== 'undefined') {
  const w = window as unknown as { __readerCache?: Record<string, unknown> }
  w.__readerCache = w.__readerCache ?? {}
  w.__readerCache.epub = {
    has: (id: number) => epubCache.has(id),
    size: () => epubCache.size(),
    stats: () => epubCache.stats(),
    resetStats: () => epubCache.resetStats()
  }
}
