import type { PDFDocumentProxy } from 'pdfjs-dist'

// Warm-restore cache for parsed PDF documents. Holds up to MAX_ENTRIES
// PDFDocumentProxy objects keyed by bookId so reopening a recently-viewed
// book skips the ~800ms PDF.js parse. The cache owns the proxy lifecycle:
// PdfView reads via getCachedPdf and never calls proxy.destroy() — that
// responsibility moves here, triggered by LRU eviction or explicit evictPdf
// (called from delete flows).

interface CacheEntry {
  proxy: PDFDocumentProxy
  bytes: Uint8Array
  lastAccess: number
}

const MAX_ENTRIES = 3
const cache = new Map<number, CacheEntry>()

export function getCachedPdf(bookId: number): CacheEntry | undefined {
  const entry = cache.get(bookId)
  if (entry) entry.lastAccess = Date.now()
  return entry
}

export function setCachedPdf(
  bookId: number,
  proxy: PDFDocumentProxy,
  bytes: Uint8Array
): void {
  const existing = cache.get(bookId)
  if (existing) {
    if (existing.proxy !== proxy) {
      void existing.proxy.destroy()
    }
    existing.proxy = proxy
    existing.bytes = bytes
    existing.lastAccess = Date.now()
    return
  }
  if (cache.size >= MAX_ENTRIES) {
    let oldestId: number | null = null
    let oldestTime = Infinity
    for (const [id, entry] of cache) {
      if (entry.lastAccess < oldestTime) {
        oldestTime = entry.lastAccess
        oldestId = id
      }
    }
    if (oldestId !== null) {
      const evicted = cache.get(oldestId)
      if (evicted) {
        void evicted.proxy.destroy()
        cache.delete(oldestId)
      }
    }
  }
  cache.set(bookId, { proxy, bytes, lastAccess: Date.now() })
}

export function evictPdf(bookId: number): void {
  const entry = cache.get(bookId)
  if (!entry) return
  void entry.proxy.destroy()
  cache.delete(bookId)
}
