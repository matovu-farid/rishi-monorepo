import { create } from 'zustand'

// Generic LRU warm-restore cache for parsed reader documents
// (PDFDocumentProxy, epubjs.Book, etc.). The cache owns the document
// lifecycle — viewers read via `get` and never call destroy themselves;
// eviction (LRU, count cap, byte budget, or explicit `evict`) destroys
// the document.
//
// Why Zustand rather than a bare module Map: keeps a single shape for
// every reader format and gives us a path to add `persist` later
// without touching consumers.

export interface ReaderCacheEntry<T> {
  document: T
  bytes: Uint8Array
  size: number
  lastAccess: number
}

export interface ReaderCacheOptions<T> {
  // Distinct Zustand store name — also useful if we later add persist.
  name: string
  // Soft upper bound on entries; LRU evicts when exceeded.
  maxEntries: number
  // Skip caching entries whose bytes exceed this — they cold-load every
  // time. Prevents one huge book from monopolising the byte budget.
  maxEntryBytes: number
  // Total bytes across all entries. After insert, LRU evicts until under.
  // Must be >= maxEntryBytes so any cacheable entry fits alone.
  maxTotalBytes: number
  destroy: (document: T) => void | Promise<void>
}

export interface ReaderCacheStats {
  hits: number
  misses: number
}

export interface ReaderCache<T> {
  get(bookId: number): ReaderCacheEntry<T> | undefined
  set(bookId: number, document: T, bytes: Uint8Array): void
  evict(bookId: number): void
  // Diagnostic surface — used by e2e tests to assert cache-hit
  // behaviour without monkey-patching the contextBridge IPC layer
  // (those exports are frozen and can't be intercepted from page
  // context). Has no impact on production behaviour.
  has(bookId: number): boolean
  size(): number
  stats(): ReaderCacheStats
  resetStats(): void
}

interface CacheState<T> {
  entries: Map<number, ReaderCacheEntry<T>>
}

export function createReaderCache<T>(opts: ReaderCacheOptions<T>): ReaderCache<T> {
  const store = create<CacheState<T>>(() => ({ entries: new Map() }))
  const entries = () => store.getState().entries
  const stats: ReaderCacheStats = { hits: 0, misses: 0 }

  const destroyEntry = (entry: ReaderCacheEntry<T>): void => {
    void opts.destroy(entry.document)
  }

  const evictOldest = (): boolean => {
    let oldestId: number | null = null
    let oldestTime = Infinity
    for (const [id, entry] of entries()) {
      if (entry.lastAccess < oldestTime) {
        oldestTime = entry.lastAccess
        oldestId = id
      }
    }
    if (oldestId === null) return false
    const evicted = entries().get(oldestId)
    if (evicted) destroyEntry(evicted)
    entries().delete(oldestId)
    return true
  }

  const totalBytes = (): number => {
    let total = 0
    for (const entry of entries().values()) total += entry.size
    return total
  }

  return {
    get(bookId) {
      const entry = entries().get(bookId)
      if (entry) {
        entry.lastAccess = Date.now()
        stats.hits++
      } else {
        stats.misses++
      }
      return entry
    },

    set(bookId, document, bytes) {
      const size = bytes.byteLength

      // Skip caching anything that exceeds the per-entry cap; drop any
      // stale entry for this id so we don't serve an older version.
      // Caller retains ownership of the new document.
      if (size > opts.maxEntryBytes) {
        const stale = entries().get(bookId)
        if (stale && stale.document !== document) {
          destroyEntry(stale)
        }
        entries().delete(bookId)
        return
      }

      const existing = entries().get(bookId)
      const now = Date.now()
      if (existing) {
        if (existing.document !== document) {
          destroyEntry(existing)
        }
        existing.document = document
        existing.bytes = bytes
        existing.size = size
        existing.lastAccess = now
      } else {
        entries().set(bookId, { document, bytes, size, lastAccess: now })
      }

      // Enforce budgets. The just-inserted entry has the newest
      // lastAccess so LRU never selects it as long as another entry
      // exists — that's our guarantee that we don't evict what we
      // just put in.
      while (entries().size > opts.maxEntries) {
        if (!evictOldest()) break
      }
      while (totalBytes() > opts.maxTotalBytes && entries().size > 1) {
        if (!evictOldest()) break
      }
    },

    evict(bookId) {
      const entry = entries().get(bookId)
      if (!entry) return
      destroyEntry(entry)
      entries().delete(bookId)
    },

    has(bookId) {
      return entries().has(bookId)
    },

    size() {
      return entries().size
    },

    stats() {
      return { ...stats }
    },

    resetStats() {
      stats.hits = 0
      stats.misses = 0
    }
  }
}
