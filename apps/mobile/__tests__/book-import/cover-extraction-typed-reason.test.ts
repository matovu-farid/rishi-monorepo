/**
 * DAT-010 (#122): the CoverPort now emits a typed
 * `CoverExtractionFailureReason` via the `onExtractionFailure`
 * callback so callers (and the future UI) can react with the right
 * copy instead of guessing what `coverPath === '__failed'` meant.
 *
 * Persisted sentinel behaviour is unchanged (covered by
 * cover-extraction-failure.test.ts); this file pins the new typed
 * surface so a future schema migration can deprecate the sentinel
 * cleanly.
 */

const mockExtractEpubCover = jest.fn()
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: (...args: unknown[]) => mockExtractEpubCover(...args),
}))

const mockExtractMobiCover = jest.fn()
jest.mock('@rishi/shared/formats/mobi', () => ({
  extractMobiCover: (...args: unknown[]) => mockExtractMobiCover(...args),
}))

jest.mock('@rishi/shared/schema', () => ({ books: { id: 'id' } }))
jest.mock('drizzle-orm', () => ({ eq: jest.fn() }))
jest.mock('@/lib/db', () => ({
  db: {
    update: jest.fn(() => ({
      set: () => ({ where: () => ({ run: jest.fn() }) }),
    })),
  },
}))
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
jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(),
  isEmbeddingReady: jest.fn(() => false),
}))
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
  type CoverExtractionFailureReason,
} from '@/lib/book-import/adapters'

describe('DAT-010 — CoverPort emits typed failure reasons', () => {
  beforeEach(() => {
    mockExtractEpubCover.mockReset()
    mockExtractMobiCover.mockReset()
  })

  it('emits kind:parse-error when the extractor throws (EPUB)', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    mockExtractEpubCover.mockRejectedValue(new Error('zip corrupt'))

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(),
      updateBookCover: jest.fn(async () => undefined),
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b1',
      bookPath: '/tmp/x.epub',
      format: 'epub',
    })

    expect(failures).toHaveLength(1)
    expect(failures[0].bookId).toBe('b1')
    expect(failures[0].reason.kind).toBe('parse-error')
    if (failures[0].reason.kind === 'parse-error') {
      expect(failures[0].reason.format).toBe('epub')
      expect(failures[0].reason.cause).toBeInstanceOf(Error)
    }
  })

  it('emits kind:parse-error when the extractor throws (MOBI)', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    mockExtractMobiCover.mockImplementation(() => {
      throw new Error('palmdoc parse error')
    })

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(),
      updateBookCover: jest.fn(async () => undefined),
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b2',
      bookPath: '/tmp/x.mobi',
      format: 'mobi',
    })

    expect(failures[0].reason.kind).toBe('parse-error')
  })

  it('emits kind:read-error when reading the book bytes fails', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => {
        throw new Error('EIO')
      }),
      writeCoverFile: jest.fn(),
      updateBookCover: jest.fn(async () => undefined),
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b3',
      bookPath: '/tmp/x.epub',
      format: 'epub',
    })

    expect(failures[0].reason.kind).toBe('read-error')
  })

  it('emits kind:no-cover-found when the extractor returns null', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    mockExtractEpubCover.mockResolvedValue(null)
    const updateBookCover = jest.fn(async () => undefined)

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(),
      updateBookCover,
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b4',
      bookPath: '/tmp/x.epub',
      format: 'epub',
    })

    expect(failures[0].reason.kind).toBe('no-cover-found')
    // CRUCIAL: "no cover" does NOT persist the failure sentinel —
    // some books legitimately have no cover and the letter-tile is
    // the right UI.
    expect(updateBookCover).not.toHaveBeenCalled()
  })

  it('emits kind:write-error when writing the cover to disk fails', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    mockExtractEpubCover.mockResolvedValue({
      mimeType: 'image/jpeg',
      data: new Uint8Array([1, 2, 3]),
    })

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(async () => {
        throw new Error('ENOSPC')
      }),
      updateBookCover: jest.fn(async () => undefined),
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b5',
      bookPath: '/tmp/x.epub',
      format: 'epub',
    })

    expect(failures[0].reason.kind).toBe('write-error')
  })

  it('emits kind:format-unsupported for PDF / DJVU and does NOT persist sentinel', async () => {
    const failures: Array<{ bookId: string; reason: CoverExtractionFailureReason }> =
      []
    const updateBookCover = jest.fn(async () => undefined)

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(),
      writeCoverFile: jest.fn(),
      updateBookCover,
      onExtractionFailure: (bookId, reason) =>
        failures.push({ bookId, reason }),
    })

    await port.extractAndStore({
      bookId: 'b6',
      bookPath: '/tmp/x.pdf',
      format: 'pdf',
    })

    expect(failures[0].reason.kind).toBe('format-unsupported')
    expect(updateBookCover).not.toHaveBeenCalled()
  })

  it('still persists the __failed sentinel on parse error (backward compat)', async () => {
    // Confirms we haven't accidentally regressed P1-AC: book-storage's
    // mapRowToBook still needs to see the sentinel.
    mockExtractEpubCover.mockRejectedValue(new Error('boom'))
    const updateBookCover = jest.fn(async () => undefined)

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(),
      updateBookCover,
    })

    await port.extractAndStore({
      bookId: 'b7',
      bookPath: '/tmp/x.epub',
      format: 'epub',
    })

    expect(updateBookCover).toHaveBeenCalledWith(
      'b7',
      COVER_EXTRACTION_FAILED_SENTINEL,
    )
  })

  it('a throwing onExtractionFailure callback does not break the pipeline', async () => {
    mockExtractEpubCover.mockRejectedValue(new Error('boom'))
    const updateBookCover = jest.fn(async () => undefined)

    const port = createMobileCoverPort({
      readBookBytes: jest.fn(async () => new Uint8Array([1])),
      writeCoverFile: jest.fn(),
      updateBookCover,
      onExtractionFailure: () => {
        throw new Error('observer crashed')
      },
    })

    // Must not throw.
    await expect(
      port.extractAndStore({
        bookId: 'b8',
        bookPath: '/tmp/x.epub',
        format: 'epub',
      }),
    ).resolves.toBeNull()
    // Sentinel still persisted.
    expect(updateBookCover).toHaveBeenCalledWith(
      'b8',
      COVER_EXTRACTION_FAILED_SENTINEL,
    )
  })
})
