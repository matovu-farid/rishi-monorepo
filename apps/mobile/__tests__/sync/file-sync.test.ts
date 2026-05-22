/**
 * CG03 + CG04 — direct tests for `lib/sync/file-sync.ts`.
 *
 * CG03: `uploadBookFile` R2 PUT failure path — when the presigned URL PUT
 * returns 5xx, the helper must throw and must NOT leave the DB in any partial
 * state (the helper writes no DB rows itself; the assertion is that the
 * surrounding `db` was never called).
 *
 * CG04 (DAT-003): `downloadBookFile` atomic-move recovery — when
 * `tmpFile.move()` fails mid-flight, the helper must:
 *   (a) KEEP the tmp file on disk (no orphaned destination, but the bytes
 *       are preserved so a retry doesn't pay the R2 download cost again),
 *   (b) throw with a recovery-friendly message,
 *   (c) NOT set `filePath` on the book row (we don't point at a non-existent
 *       destination), and
 *   (d) flip the `fileNeedsRedownload` DB flag + push the failure into the
 *       download-error store so the UI has a retry affordance.
 *
 * Native modules (expo-file-system, expo-crypto, drizzle, db, apiClient) are
 * stubbed at the JS boundary so we exercise the real `file-sync.ts` logic.
 */

// ────────────────────────────────────────────────────────────────────────────
// Schema + drizzle-orm stubs (avoid drizzle-orm/sqlite-core resolution)
// ────────────────────────────────────────────────────────────────────────────

jest.mock('@rishi/shared/schema', () => ({
  books: {
    id: 'id',
    filePath: 'filePath',
    fileNeedsRedownload: 'fileNeedsRedownload',
  },
}))

jest.mock('drizzle-orm', () => ({
  eq: jest.fn((col: unknown, val: unknown) => ({ eq: [col, val] })),
}))

// ────────────────────────────────────────────────────────────────────────────
// expo-file-system fake — File / Directory / Paths
// ────────────────────────────────────────────────────────────────────────────

type FakeFile = {
  uri: string
  exists: boolean
  bytes: jest.Mock
  base64: jest.Mock
  write: jest.Mock
  move: jest.Mock
  delete: jest.Mock
}

const fakeFiles = new Map<string, FakeFile>()

function makeFakeFile(uri: string): FakeFile {
  const file: FakeFile = {
    uri,
    exists: true,
    bytes: jest.fn(async () => new Uint8Array([1, 2, 3])),
    base64: jest.fn(async () => 'ZmFrZQ=='),
    write: jest.fn(),
    move: jest.fn(),
    delete: jest.fn(() => {
      file.exists = false
    }),
  }
  return file
}

jest.mock('expo-file-system', () => {
  const FileCtor = jest.fn().mockImplementation((arg1: unknown, arg2?: string) => {
    let uri: string
    if (arg2 === undefined) {
      uri = typeof arg1 === 'string' ? arg1 : ((arg1 as { uri?: string })?.uri ?? '')
    } else {
      const base = typeof arg1 === 'string' ? arg1 : ((arg1 as { uri?: string })?.uri ?? '')
      uri = `${base}/${arg2}`
    }
    if (!fakeFiles.has(uri)) {
      fakeFiles.set(uri, makeFakeFile(uri))
    }
    return fakeFiles.get(uri)!
  }) as unknown as jest.Mock

  const DirectoryCtor = jest.fn().mockImplementation((...parts: unknown[]) => {
    // Support new Directory(base) | new Directory(base, name) | new Directory(base, name1, name2)
    const segs = parts.map((p) =>
      typeof p === 'string' ? p : ((p as { uri?: string })?.uri ?? ''),
    )
    const uri = segs.filter(Boolean).join('/')
    return {
      uri,
      exists: true,
      create: jest.fn(),
    }
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
  }
})

// ────────────────────────────────────────────────────────────────────────────
// expo-crypto fake
// ────────────────────────────────────────────────────────────────────────────

jest.mock('expo-crypto', () => ({
  digestStringAsync: jest.fn(async () => 'fake-hash-abc'),
  CryptoDigestAlgorithm: { SHA256: 'SHA-256' },
}))

// ────────────────────────────────────────────────────────────────────────────
// DB stub — record every call so the tests can assert nothing leaks on error.
// ────────────────────────────────────────────────────────────────────────────

const dbRecord = {
  updateCalls: [] as Array<{ values: unknown; where: unknown }>,
}

function makeDbStub() {
  return {
    update: jest.fn(() => ({
      set: (values: unknown) => ({
        where: (where: unknown) => ({
          run: () => {
            dbRecord.updateCalls.push({ values, where })
          },
        }),
      }),
    })),
  }
}

const mockDb = makeDbStub()

jest.mock('@/lib/db', () => ({
  db: mockDb,
}))

// ────────────────────────────────────────────────────────────────────────────
// apiClient stub — script per-test responses.
// ────────────────────────────────────────────────────────────────────────────

const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({
  apiClient: (...args: unknown[]) => mockApiClient(...args),
}))

// ────────────────────────────────────────────────────────────────────────────
// Global fetch stub (R2 PUT/GET goes through global fetch, not apiClient).
// ────────────────────────────────────────────────────────────────────────────

const realFetch = global.fetch
const mockFetch = jest.fn()
beforeAll(() => {
  global.fetch = mockFetch as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = realFetch
})

// ────────────────────────────────────────────────────────────────────────────
// Imports — after mocks
// ────────────────────────────────────────────────────────────────────────────

import { uploadBookFile, downloadBookFile, UploadLimitError } from '@/lib/sync/file-sync'
import {
  useDownloadErrorStore,
  getFailedDownloads,
} from '@/lib/sync/download-error-store'

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, init: { ok?: boolean; status?: number; statusText?: string } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    statusText: init.statusText ?? 'OK',
    json: async () => body,
  } as unknown as Response
}

function bytesResponse(init: { ok?: boolean; status?: number; statusText?: string } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    statusText: init.statusText ?? 'OK',
    arrayBuffer: async () => new ArrayBuffer(4),
  } as unknown as Response
}

function resetAll(): void {
  fakeFiles.clear()
  dbRecord.updateCalls.length = 0
  mockApiClient.mockReset()
  mockFetch.mockReset()
  jest.clearAllMocks()
  // DAT-003: reset the recovery store between tests so failure entries
  // from a previous case don't bleed into assertions.
  useDownloadErrorStore.getState().clear()
}

// ────────────────────────────────────────────────────────────────────────────
// CG03 — uploadBookFile failure paths
// ────────────────────────────────────────────────────────────────────────────

describe('uploadBookFile — CG03 R2 PUT failure', () => {
  beforeEach(() => resetAll())

  it('throws when the presigned URL PUT returns 5xx and writes no DB rows', async () => {
    // Worker hands back a presigned URL (file not yet in R2).
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        exists: false,
        uploadUrl: 'https://r2.example.com/upload?sig=abc',
        r2Key: 'r2/epub/fake-hash',
      }),
    )

    // R2 PUT fails with 503.
    mockFetch.mockResolvedValueOnce(
      bytesResponse({ ok: false, status: 503, statusText: 'Service Unavailable' }),
    )

    await expect(
      uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 1024),
    ).rejects.toThrow(/R2 upload failed: 503/)

    // The R2 PUT was attempted exactly once via the presigned URL.
    expect(mockFetch).toHaveBeenCalledTimes(1)
    const putCall = mockFetch.mock.calls[0]
    expect(putCall[0]).toBe('https://r2.example.com/upload?sig=abc')
    expect((putCall[1] as RequestInit).method).toBe('PUT')

    // No partial DB state — file-sync.ts never writes the books row itself,
    // and on this failure path it must NOT call into the DB at all.
    expect(mockDb.update).not.toHaveBeenCalled()
    expect(dbRecord.updateCalls).toHaveLength(0)
  })

  it('throws when the upload-url API call itself fails (non-ok response)', async () => {
    mockApiClient.mockResolvedValueOnce(
      jsonResponse(null, { ok: false, status: 500, statusText: 'Internal Server Error' }),
    )

    await expect(
      uploadBookFile('/docs/books/b1/book.pdf', 'fake-hash', 'pdf', 1024),
    ).rejects.toThrow(/Upload URL request failed: 500/)

    // R2 was never reached — only the upload-url call happened.
    expect(mockFetch).not.toHaveBeenCalled()
    expect(mockDb.update).not.toHaveBeenCalled()
  })

  it('skips the R2 PUT when the worker reports the hash already exists (dedup)', async () => {
    // Dedup branch — control: verify we did NOT call fetch.
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        exists: true,
        r2Key: 'r2/epub/already-there',
      }),
    )

    const result = await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 1024)

    expect(result.r2Key).toBe('r2/epub/already-there')
    expect(mockFetch).not.toHaveBeenCalled()
    expect(mockDb.update).not.toHaveBeenCalled()
  })
})

// ────────────────────────────────────────────────────────────────────────────
// CG04 — downloadBookFile atomic-move rollback
// ────────────────────────────────────────────────────────────────────────────

describe('downloadBookFile — CG04 atomic move rollback', () => {
  beforeEach(() => resetAll())

  it('preserves tmp file, sets fileNeedsRedownload, and pushes failure to recovery store when move() fails', async () => {
    // Worker hands back a presigned download URL.
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        downloadUrl: 'https://r2.example.com/download?sig=def',
        expiresIn: 3600,
      }),
    )

    // R2 GET succeeds — file bytes arrive.
    mockFetch.mockResolvedValueOnce(bytesResponse())

    // Pre-seed the tmp file fake so we can spy on its move/delete calls. The
    // production code constructs `new File(bookDir, 'book.epub.tmp')` which
    // our fake will deduplicate against this URI.
    const tmpUri = '/docs/books/book-123/book.epub.tmp'
    const tmpFile = makeFakeFile(tmpUri)
    // Make move() throw to simulate a mid-flight filesystem failure.
    tmpFile.move.mockImplementation(() => {
      throw new Error('EBUSY: device busy, rename')
    })
    fakeFiles.set(tmpUri, tmpFile)

    await expect(downloadBookFile('book-123', 'r2/epub/hash', 'epub')).rejects.toThrow(
      /Failed to move temp file to final path/,
    )

    // (a) tmp file write was attempted.
    expect(tmpFile.write).toHaveBeenCalledTimes(1)
    // (b) move was attempted and threw.
    expect(tmpFile.move).toHaveBeenCalledTimes(1)
    // (c) DAT-003 recovery: the tmp file MUST NOT be deleted — keeping it
    //     means the user's next retry doesn't have to redownload the bytes
    //     from R2. We only need to retry the move, not the network fetch.
    expect(tmpFile.delete).not.toHaveBeenCalled()
    // (d) DB was updated, but ONLY to flip the recovery flag — not to point
    //     `filePath` at a destination that doesn't exist on disk.
    expect(mockDb.update).toHaveBeenCalledTimes(1)
    expect(dbRecord.updateCalls).toHaveLength(1)
    const updateValues = dbRecord.updateCalls[0].values as Record<string, unknown>
    expect(updateValues.fileNeedsRedownload).toBe(true)
    expect(updateValues.filePath).toBeUndefined()
    // (e) the recovery store has an entry the UI can render as a retry list.
    const failures = getFailedDownloads()
    expect(failures).toHaveLength(1)
    expect(failures[0]).toMatchObject({
      bookId: 'book-123',
      r2Key: 'r2/epub/hash',
      format: 'epub',
    })
    expect(failures[0].reason).toMatch(/EBUSY|move/i)
  })

  it('throws and writes no DB rows when the presigned download URL call fails', async () => {
    mockApiClient.mockResolvedValueOnce(
      jsonResponse(null, { ok: false, status: 404, statusText: 'Not Found' }),
    )

    await expect(downloadBookFile('book-404', 'r2/epub/missing', 'epub')).rejects.toThrow(
      /Download URL request failed: 404/,
    )

    expect(mockFetch).not.toHaveBeenCalled()
    expect(mockDb.update).not.toHaveBeenCalled()
  })

  it('throws and writes no DB rows when the R2 GET returns 5xx', async () => {
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        downloadUrl: 'https://r2.example.com/download?sig=ghi',
        expiresIn: 3600,
      }),
    )

    mockFetch.mockResolvedValueOnce(
      bytesResponse({ ok: false, status: 502, statusText: 'Bad Gateway' }),
    )

    await expect(downloadBookFile('book-502', 'r2/epub/hash', 'epub')).rejects.toThrow(
      /R2 download failed: 502/,
    )

    expect(mockDb.update).not.toHaveBeenCalled()
  })

  it('updates DB filePath on the happy path (sanity — atomic move succeeds)', async () => {
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        downloadUrl: 'https://r2.example.com/download?sig=ok',
        expiresIn: 3600,
      }),
    )

    mockFetch.mockResolvedValueOnce(bytesResponse())

    const result = await downloadBookFile('book-ok', 'r2/epub/hash', 'epub')

    // Final filePath points at book.epub (not book.epub.tmp).
    expect(result).toMatch(/book\.epub$/)
    // DB was updated with the final path.
    expect(mockDb.update).toHaveBeenCalledTimes(1)
    expect(dbRecord.updateCalls).toHaveLength(1)
    expect((dbRecord.updateCalls[0].values as { filePath: string }).filePath).toMatch(
      /book\.epub$/,
    )
  })
})

// ────────────────────────────────────────────────────────────────────────────
// fileSize wiring + storage-cap error mapping
// ────────────────────────────────────────────────────────────────────────────

describe('uploadBookFile — fileSize in request body', () => {
  beforeEach(() => resetAll())

  it('includes the explicit fileSize argument in the POST body', async () => {
    mockApiClient.mockResolvedValueOnce(
      jsonResponse({
        exists: false,
        uploadUrl: 'https://r2.example.com/upload?sig=ok',
        r2Key: 'r2/epub/sized',
      }),
    )
    mockFetch.mockResolvedValueOnce(bytesResponse())

    await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 12345)

    expect(mockApiClient).toHaveBeenCalledTimes(1)
    const [path, init] = mockApiClient.mock.calls[0] as [string, RequestInit]
    expect(path).toBe('/api/sync/upload-url')
    expect(init.method).toBe('POST')
    const parsed = JSON.parse(init.body as string) as Record<string, unknown>
    expect(parsed.fileHash).toBe('fake-hash')
    expect(parsed.contentType).toBe('application/epub+zip')
    expect(parsed.fileSize).toBe(12345)
  })
})

describe('uploadBookFile — storage-cap error mapping', () => {
  beforeEach(() => resetAll())

  it('throws UploadLimitError with code FILE_TOO_LARGE on 413', async () => {
    mockApiClient.mockResolvedValueOnce({
      ok: false,
      status: 413,
      statusText: 'Payload Too Large',
      json: async () => ({
        error: 'File exceeds 800 MB cap',
        code: 'FILE_TOO_LARGE',
        limit: 800 * 1024 * 1024,
      }),
    } as unknown as Response)

    let caught: unknown = null
    try {
      await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 900 * 1024 * 1024)
    } catch (e) {
      caught = e
    }

    expect(caught).toBeInstanceOf(UploadLimitError)
    const err = caught as UploadLimitError
    expect(err.code).toBe('FILE_TOO_LARGE')
    expect(err.limit).toBe(800 * 1024 * 1024)
    expect(err.status).toBe(413)
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it('throws UploadLimitError with code BOOK_LIMIT_REACHED on 507 book cap', async () => {
    mockApiClient.mockResolvedValueOnce({
      ok: false,
      status: 507,
      statusText: 'Insufficient Storage',
      json: async () => ({
        error: 'Book count exceeds limit',
        code: 'BOOK_LIMIT_REACHED',
        limit: 500,
        current: 500,
      }),
    } as unknown as Response)

    let caught: unknown = null
    try {
      await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 1024)
    } catch (e) {
      caught = e
    }

    expect(caught).toBeInstanceOf(UploadLimitError)
    const err = caught as UploadLimitError
    expect(err.code).toBe('BOOK_LIMIT_REACHED')
    expect(err.limit).toBe(500)
    expect(err.current).toBe(500)
    expect(err.status).toBe(507)
  })

  it('throws UploadLimitError with code STORAGE_LIMIT_REACHED on 507 storage cap', async () => {
    mockApiClient.mockResolvedValueOnce({
      ok: false,
      status: 507,
      statusText: 'Insufficient Storage',
      json: async () => ({
        error: 'Total storage exceeded',
        code: 'STORAGE_LIMIT_REACHED',
        limit: 10 * 1024 * 1024 * 1024,
        current: 9.5 * 1024 * 1024 * 1024,
      }),
    } as unknown as Response)

    let caught: unknown = null
    try {
      await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub', 1024 * 1024)
    } catch (e) {
      caught = e
    }

    expect(caught).toBeInstanceOf(UploadLimitError)
    const err = caught as UploadLimitError
    expect(err.code).toBe('STORAGE_LIMIT_REACHED')
    expect(err.limit).toBe(10 * 1024 * 1024 * 1024)
  })
})
