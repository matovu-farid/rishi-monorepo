/**
 * Mobile book-import CoverPort — defect P1-AC.
 *
 * Cover-extraction failures previously returned silently, leaving the
 * book row with `coverPath = null` and no signal to the UI that the
 * cover *could* exist but failed to extract. The library showed a
 * letter-tile fallback with no retry affordance, indistinguishable from
 * a book that legitimately has no cover.
 *
 * Pragmatic fix (no schema migration): persist the sentinel
 * `'__failed'` into the existing `coverPath` column when extraction
 * fails. The DB column already accepts strings; the BookRow + mapper
 * code path interpret that sentinel as `coverExtractionFailed = true`
 * and `coverPath = null`. A future migration can promote this to a
 * dedicated boolean column.
 *
 * Behaviour pinned here:
 *   1. EPUB cover extraction throwing causes the port to call
 *      `updateBookCover(bookId, '__failed')` instead of returning null
 *      silently.
 *   2. The port still resolves null (not throw) so the caller's
 *      import pipeline is unaffected.
 *   3. The same path is taken for MOBI/AZW3 extractor errors.
 */

// ── Mock shared extractor modules so tests control success/failure. ─────────
const mockExtractEpubCover = jest.fn()
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: (...args: unknown[]) => mockExtractEpubCover(...args),
}))

const mockExtractMobiCover = jest.fn()
jest.mock('@rishi/shared/formats/mobi', () => ({
  extractMobiCover: (...args: unknown[]) => mockExtractMobiCover(...args),
}))

// Schema + drizzle ops — tests don't exercise the DB directly. The port's
// `updateBookCover` runs through the injected deps below, so the underlying
// `db.update(...)` chain is never invoked.
jest.mock('@rishi/shared/schema', () => ({ books: { id: 'id' } }))
jest.mock('drizzle-orm', () => ({ eq: jest.fn() }))
jest.mock('@/lib/db', () => ({ db: { update: jest.fn(() => ({ set: () => ({ where: () => ({ run: jest.fn() }) }) })) } }))
jest.mock('@/lib/sync/file-sync', () => ({
  hashBookFile: jest.fn(),
  uploadBookFile: jest.fn(),
  UploadLimitError: class extends Error {},
}))
jest.mock('@/lib/sync/upload-error-store', () => ({
  useUploadErrorStore: { getState: () => ({ show: jest.fn() }) },
}))
jest.mock('@/lib/sync/triggers', () => ({ triggerSyncOnWrite: jest.fn() }))
jest.mock('@/lib/rag/chunker', () => ({ getChunks: jest.fn() }))
jest.mock('@/lib/rag/embedder', () => ({ embedBatch: jest.fn(), isEmbeddingReady: jest.fn(() => false) }))
jest.mock('@/lib/rag/server-fallback', () => ({ embedTextsOnServer: jest.fn() }))
jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn(),
  isBookEmbedded: jest.fn(() => false),
}))
jest.mock('expo-file-system', () => ({
  File: jest.fn(),
  Directory: jest.fn(),
  Paths: { document: '/docs' },
}))

import {
  createMobileCoverPort,
  COVER_EXTRACTION_FAILED_SENTINEL,
} from '@/lib/book-import/adapters'

describe('CoverPort cover-extraction failure (P1-AC)', () => {
  beforeEach(() => {
    mockExtractEpubCover.mockReset()
    mockExtractMobiCover.mockReset()
  })

  it('persists the __failed sentinel when EPUB cover extraction throws', async () => {
    const readBookBytes = jest.fn(async () => new Uint8Array([1, 2, 3]))
    const writeCoverFile = jest.fn()
    const updateBookCover = jest.fn(async () => undefined)

    mockExtractEpubCover.mockRejectedValue(new Error('zip corrupt'))

    const port = createMobileCoverPort({
      readBookBytes,
      writeCoverFile,
      updateBookCover,
    })

    const result = await port.extractAndStore({
      bookId: 'book-1',
      bookPath: '/tmp/foo.epub',
      format: 'epub',
    })

    expect(result).toBeNull()
    expect(writeCoverFile).not.toHaveBeenCalled()
    expect(updateBookCover).toHaveBeenCalledTimes(1)
    expect(updateBookCover).toHaveBeenCalledWith(
      'book-1',
      COVER_EXTRACTION_FAILED_SENTINEL,
    )
  })

  it('persists the sentinel when the MOBI extractor throws', async () => {
    const readBookBytes = jest.fn(async () => new Uint8Array([1]))
    const writeCoverFile = jest.fn()
    const updateBookCover = jest.fn(async () => undefined)

    mockExtractMobiCover.mockImplementation(() => {
      throw new Error('palmdoc parse error')
    })

    const port = createMobileCoverPort({
      readBookBytes,
      writeCoverFile,
      updateBookCover,
    })

    const result = await port.extractAndStore({
      bookId: 'book-2',
      bookPath: '/tmp/foo.mobi',
      format: 'mobi',
    })

    expect(result).toBeNull()
    expect(updateBookCover).toHaveBeenCalledWith(
      'book-2',
      COVER_EXTRACTION_FAILED_SENTINEL,
    )
  })

  it('does NOT persist the sentinel for formats that have no extractor (pdf/djvu)', async () => {
    const updateBookCover = jest.fn(async () => undefined)
    const port = createMobileCoverPort({
      readBookBytes: jest.fn(),
      writeCoverFile: jest.fn(),
      updateBookCover,
    })

    const result = await port.extractAndStore({
      bookId: 'book-3',
      bookPath: '/tmp/foo.pdf',
      format: 'pdf',
    })

    expect(result).toBeNull()
    expect(updateBookCover).not.toHaveBeenCalled()
  })

  it('does NOT persist the sentinel on the happy path', async () => {
    const writeCoverFile = jest.fn(async () => 'file:///covers/book-4.jpg')
    const updateBookCover = jest.fn(async () => undefined)

    mockExtractEpubCover.mockResolvedValue({
      mimeType: 'image/jpeg',
      data: new Uint8Array([1, 2, 3]),
    })

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1, 2, 3])),
      writeCoverFile,
      updateBookCover,
    })

    const result = await port.extractAndStore({
      bookId: 'book-4',
      bookPath: '/tmp/foo.epub',
      format: 'epub',
    })

    expect(result).toBe('file:///covers/book-4.jpg')
    expect(updateBookCover).toHaveBeenCalledWith(
      'book-4',
      'file:///covers/book-4.jpg',
    )
    expect(updateBookCover).not.toHaveBeenCalledWith(
      'book-4',
      COVER_EXTRACTION_FAILED_SENTINEL,
    )
  })
})
