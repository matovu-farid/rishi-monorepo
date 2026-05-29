import { describe, it, expect } from 'vitest'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import { getCachedPdf, setCachedPdf, evictPdf } from './pdf-cache'

function makeProxy(id: string): PDFDocumentProxy {
  // Only fields the cache touches (destroy) need to be present. The real
  // proxy is parsed by pdf.js; for cache-level tests an opaque shape with
  // a destroy() method is enough.
  return { id, destroy: () => Promise.resolve() } as unknown as PDFDocumentProxy
}

describe('pdf-cache — version-aware lookup', () => {
  it('returns a miss when the requested version differs from the cached version', () => {
    const bookId = 9001
    setCachedPdf(bookId, makeProxy('v1'), new Uint8Array(10), 1)

    const hit = getCachedPdf(bookId, 1)
    expect(hit?.document).toBeDefined()

    // A re-import bumps book.version. The cache must not serve the
    // previous parse — bytes on disk now belong to a different file.
    const stale = getCachedPdf(bookId, 2)
    expect(stale).toBeUndefined()

    evictPdf(bookId)
  })
})
