import type { PDFDocumentProxy } from 'pdfjs-dist'
import { createReaderCache } from './cache'

// Warm-restore cache for parsed PDF documents. PdfView reads via
// getCachedPdf and never calls proxy.destroy() — the cache owns the
// proxy lifecycle, triggered by LRU eviction, byte-budget pressure,
// or explicit evictPdf (called from delete flows).

const pdfCache = createReaderCache<PDFDocumentProxy>({
  name: 'pdf',
  maxEntries: 3,
  maxEntryBytes: 50_000_000,
  maxTotalBytes: 150_000_000,
  destroy: (proxy) => proxy.destroy()
})

// `version` is book.version from the DB row. Pass it through so a
// re-imported file with the same bookId but a bumped version doesn't get
// the stale parsed proxy. Callers that genuinely don't have a version
// (legacy code paths) can omit it — the cache then ignores versioning.
export const getCachedPdf = (bookId: number, version?: number) => pdfCache.get(bookId, version)
export const setCachedPdf = (
  bookId: number,
  proxy: PDFDocumentProxy,
  bytes: Uint8Array,
  version?: number
): void => pdfCache.set(bookId, proxy, bytes, version)
export const evictPdf = (bookId: number): void => pdfCache.evict(bookId)

// Diagnostic handle for e2e tests. See epub-cache.ts for rationale.
if (typeof window !== 'undefined') {
  const w = window as unknown as { __readerCache?: Record<string, unknown> }
  w.__readerCache = w.__readerCache ?? {}
  w.__readerCache.pdf = {
    has: (id: number) => pdfCache.has(id),
    size: () => pdfCache.size(),
    stats: () => pdfCache.stats(),
    resetStats: () => pdfCache.resetStats()
  }
}
