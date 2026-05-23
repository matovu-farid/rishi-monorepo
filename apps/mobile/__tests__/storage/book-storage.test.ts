/**
 * Lazy R2 download in `book-storage.getBookForReading`.
 *
 * Scenario: a book row is pulled from D1 to mobile via /api/sync/pull. The row
 * has `fileR2Key` set (uploaded from desktop) but `filePath` points at a path
 * that doesn't yet exist on this device. When the reader screen calls
 * `getBookForReading(id)`, the helper must detect the missing local file and
 * call `downloadBookFile()` to fetch it from R2 before handing the Book row
 * back. If the file already exists, the helper must NOT trigger a download.
 *
 * We stub expo-file-system, drizzle, db, and file-sync at the JS boundary so
 * the test exercises the real branching in book-storage.
 */

// ────────────────────────────────────────────────────────────────────────────
// Schema + drizzle stubs
// ────────────────────────────────────────────────────────────────────────────

jest.mock('@rishi/shared/schema', () => ({
  books: {
    id: 'id',
    filePath: 'filePath',
    fileR2Key: 'fileR2Key',
    isDeleted: 'isDeleted',
  },
}))

// DAT-008 (#121): deleteBook MUST cascade vector deletion. The mock lets us
// observe whether `deleteBookChunks(bookId)` is invoked from `deleteBook`.
const deleteBookChunksMock = jest.fn()
jest.mock('@/lib/rag/vector-store', () => ({
  deleteBookChunks: (...args: unknown[]) => deleteBookChunksMock(...args),
}))

jest.mock('drizzle-orm', () => ({
  eq: jest.fn((_col, _val) => ({ eq: [_col, _val] })),
  and: jest.fn((...args: unknown[]) => ({ and: args })),
  or: jest.fn((...args: unknown[]) => ({ or: args })),
  desc: jest.fn((col: unknown) => ({ desc: col })),
  isNotNull: jest.fn((col: unknown) => ({ isNotNull: col })),
}))

// ────────────────────────────────────────────────────────────────────────────
// expo-file-system fake — File with a controllable `.exists` flag.
// ────────────────────────────────────────────────────────────────────────────

const fakeFileExistsMap = new Map<string, boolean>()

jest.mock('expo-file-system', () => {
  const FileCtor = jest.fn().mockImplementation((arg1: unknown) => {
    const uri =
      typeof arg1 === 'string' ? arg1 : ((arg1 as { uri?: string })?.uri ?? '')
    return {
      uri,
      get exists() {
        return fakeFileExistsMap.get(uri) ?? false
      },
    }
  })
  return {
    File: FileCtor,
    Directory: jest.fn(),
    Paths: { document: '/docs' },
  }
})

// ────────────────────────────────────────────────────────────────────────────
// triggerSyncOnWrite — no-op stub (called inside book-storage write paths).
// ────────────────────────────────────────────────────────────────────────────

jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: jest.fn(),
}))

// ────────────────────────────────────────────────────────────────────────────
// file-sync.downloadBookFile — record invocation.
// ────────────────────────────────────────────────────────────────────────────

const downloadBookFile = jest.fn(async (id: string, _r2Key: string, format: string) => {
  // Simulate the download writing the file to disk and updating filePath.
  const newPath = `/docs/books/${id}/book.${format}`
  fakeFileExistsMap.set(newPath, true)
  // The real downloadBookFile updates DB.filePath; our select-after-download
  // mock returns the updated row directly so the assertion is downstream.
  return newPath
})

jest.mock('@/lib/sync/file-sync', () => ({
  downloadBookFile: (...args: unknown[]) =>
    downloadBookFile(args[0] as string, args[1] as string, args[2] as string),
}))

// ────────────────────────────────────────────────────────────────────────────
// db stub — script `db.select(...).from(books).where(...).get()` per call.
// ────────────────────────────────────────────────────────────────────────────

const getResults: unknown[] = []

const selectChain = {
  from: jest.fn().mockImplementation(() => ({
    where: jest.fn().mockImplementation(() => ({
      get: jest.fn().mockImplementation(() => {
        // Each select-and-get consumes one scripted result, FIFO.
        return getResults.shift()
      }),
    })),
  })),
}

const mockDb = {
  select: jest.fn().mockReturnValue(selectChain),
  insert: jest.fn(),
  update: jest.fn().mockReturnValue({
    set: jest.fn().mockReturnValue({
      where: jest.fn().mockReturnValue({ run: jest.fn() }),
    }),
  }),
}

jest.mock('@/lib/db', () => ({
  db: mockDb,
}))

// ────────────────────────────────────────────────────────────────────────────
// Imports — after mocks
// ────────────────────────────────────────────────────────────────────────────

import { getBookForReading, deleteBook } from '@/lib/book-storage'

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

interface FakeRow {
  id: string
  title: string
  author: string
  coverPath: string | null
  filePath: string | null
  format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
  currentCfi: string | null
  currentPage: number | null
  fileR2Key: string | null
  createdAt: number
}

function makeRow(overrides: Partial<FakeRow> = {}): FakeRow {
  return {
    id: 'book-1',
    title: 'Test Book',
    author: 'Unknown',
    coverPath: null,
    filePath: '/docs/books/book-1/book.epub',
    format: 'epub',
    currentCfi: null,
    currentPage: null,
    fileR2Key: null,
    createdAt: 1,
    ...overrides,
  }
}

function resetAll(): void {
  fakeFileExistsMap.clear()
  getResults.length = 0
  downloadBookFile.mockClear()
  mockDb.select.mockClear()
  mockDb.update.mockClear()
  deleteBookChunksMock.mockClear()
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

describe('getBookForReading — lazy R2 download', () => {
  beforeEach(() => resetAll())

  it('downloads from R2 when filePath does not resolve but fileR2Key is set', async () => {
    const row = makeRow({
      id: 'book-pulled',
      filePath: '/docs/books/book-pulled/book.epub',
      fileR2Key: 'r2/epub/abcd1234',
    })
    // Initial select returns the pulled row; second select (after download)
    // returns the same row shape — book-storage re-fetches once the file is
    // on disk.
    getResults.push(row, { ...row })
    // filePath is NOT on disk before the download.
    expect(fakeFileExistsMap.get(row.filePath as string)).toBeUndefined()

    const result = await getBookForReading('book-pulled')

    expect(downloadBookFile).toHaveBeenCalledTimes(1)
    expect(downloadBookFile).toHaveBeenCalledWith(
      'book-pulled',
      'r2/epub/abcd1234',
      'epub',
    )
    expect(result?.id).toBe('book-pulled')
  })

  it('maps azw3 → mobi when calling downloadBookFile (R2 bucket convention)', async () => {
    const row = makeRow({
      id: 'book-azw3',
      filePath: '/docs/books/book-azw3/book.azw3',
      format: 'azw3',
      fileR2Key: 'r2/mobi/azw3hash',
    })
    getResults.push(row, { ...row })

    await getBookForReading('book-azw3')

    expect(downloadBookFile).toHaveBeenCalledWith(
      'book-azw3',
      'r2/mobi/azw3hash',
      'mobi',
    )
  })

  it('does NOT call downloadBookFile when the local file exists', async () => {
    const row = makeRow({
      id: 'book-local',
      filePath: '/docs/books/book-local/book.epub',
      fileR2Key: 'r2/epub/has-local',
    })
    fakeFileExistsMap.set(row.filePath as string, true)
    getResults.push(row)

    const result = await getBookForReading('book-local')

    expect(downloadBookFile).not.toHaveBeenCalled()
    expect(result?.id).toBe('book-local')
  })

  it('does NOT call downloadBookFile when fileR2Key is null (no remote copy)', async () => {
    const row = makeRow({
      id: 'book-local-only',
      filePath: '/docs/books/missing-but-no-remote/book.epub',
      fileR2Key: null,
    })
    // Local file is also missing — but there's no fileR2Key, so the helper
    // can't recover. It should still return the row so the reader can show
    // its "Book file not available" branch.
    getResults.push(row)

    const result = await getBookForReading('book-local-only')

    expect(downloadBookFile).not.toHaveBeenCalled()
    // Returned row is the original — caller decides what to do with a
    // dangling filePath.
    expect(result?.id).toBe('book-local-only')
  })

  it('returns null when the row is missing', async () => {
    getResults.push(undefined)

    const result = await getBookForReading('nope')

    expect(result).toBeNull()
    expect(downloadBookFile).not.toHaveBeenCalled()
  })

  it('invokes onDownloadStart before triggering the R2 fetch', async () => {
    const row = makeRow({
      id: 'book-cb',
      filePath: '/docs/books/book-cb/book.epub',
      fileR2Key: 'r2/epub/cb',
    })
    getResults.push(row, { ...row })

    const onDownloadStart = jest.fn()
    await getBookForReading('book-cb', { onDownloadStart })

    expect(onDownloadStart).toHaveBeenCalledTimes(1)
    expect(downloadBookFile).toHaveBeenCalledTimes(1)
    // The callback fires BEFORE the network call (so the UI can flip its
    // "Downloading..." state before the await resolves).
    const callbackOrder = onDownloadStart.mock.invocationCallOrder[0]
    const downloadOrder = downloadBookFile.mock.invocationCallOrder[0]
    expect(callbackOrder).toBeLessThan(downloadOrder)
  })

  it('does NOT invoke onDownloadStart when the local file exists', async () => {
    const row = makeRow({
      id: 'book-local-cb',
      filePath: '/docs/books/book-local-cb/book.epub',
      fileR2Key: 'r2/epub/local-cb',
    })
    fakeFileExistsMap.set(row.filePath as string, true)
    getResults.push(row)

    const onDownloadStart = jest.fn()
    await getBookForReading('book-local-cb', { onDownloadStart })

    expect(onDownloadStart).not.toHaveBeenCalled()
  })
})

// DAT-008 (#121): deleteBook used to flip `isDeleted` on the row only — chunks
// + their vec0 vectors stayed in the DB indefinitely. If the book got
// re-imported with the same id, the stale RAG context would surface in chat;
// at minimum disk grows on every delete. `deleteBook` must cascade into
// `deleteBookChunks(id)` from the same call site.
describe('deleteBook — cascade chunks/vectors', () => {
  beforeEach(() => resetAll())

  it('calls deleteBookChunks with the same bookId when soft-deleting a book', () => {
    deleteBook('book-1')
    expect(deleteBookChunksMock).toHaveBeenCalledTimes(1)
    expect(deleteBookChunksMock).toHaveBeenCalledWith('book-1')
  })

  it('still soft-deletes the row even if vector deletion throws', () => {
    deleteBookChunksMock.mockImplementationOnce(() => {
      throw new Error('vec0 not loaded')
    })
    // Should not throw — the row-level soft-delete must still proceed so
    // the user's "delete book" tap doesn't appear to fail.
    expect(() => deleteBook('book-2')).not.toThrow()
    // The drizzle update chain was still called for the books row.
    expect(mockDb.update).toHaveBeenCalled()
  })
})
