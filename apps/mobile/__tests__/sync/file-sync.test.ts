/**
 * CG03 + CG04 — direct tests for `lib/sync/file-sync.ts`.
 *
 * CG03: `uploadBookFile` R2 PUT failure path — when the presigned URL PUT
 * returns 5xx, the helper must throw and must NOT leave the DB in any partial
 * state (the helper writes no DB rows itself; the assertion is that the
 * surrounding `db` was never called).
 *
 * CG04: `downloadBookFile` atomic-move rollback — when `tmpFile.move()` fails
 * mid-flight, the helper must (a) delete the tmp file (no orphan), (b) throw,
 * and (c) never invoke the DB update that would set `filePath` on the book row
 * (no orphan `localPath`).
 *
 * Native modules (expo-file-system, expo-crypto, drizzle, db, apiClient) are
 * stubbed at the JS boundary so we exercise the real `file-sync.ts` logic.
 */

// ────────────────────────────────────────────────────────────────────────────
// Schema + drizzle-orm stubs (avoid drizzle-orm/sqlite-core resolution)
// ────────────────────────────────────────────────────────────────────────────

jest.mock('@rishi/shared/schema', () => ({
  books: { id: 'id', filePath: 'filePath' },
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

import { uploadBookFile, downloadBookFile } from '@/lib/sync/file-sync'

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

    await expect(uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub')).rejects.toThrow(
      /R2 upload failed: 503/,
    )

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

    await expect(uploadBookFile('/docs/books/b1/book.pdf', 'fake-hash', 'pdf')).rejects.toThrow(
      /Upload URL request failed: 500/,
    )

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

    const result = await uploadBookFile('/docs/books/b1/book.epub', 'fake-hash', 'epub')

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

  it('rolls back tmp file and does NOT update DB filePath when move() fails', async () => {
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
    // (c) cleanup ran — the orphan tmp was deleted.
    expect(tmpFile.delete).toHaveBeenCalledTimes(1)
    // (d) crucially: the DB was NOT updated with a filePath pointing at a
    //     non-existent destination. No orphan `localPath`.
    expect(mockDb.update).not.toHaveBeenCalled()
    expect(dbRecord.updateCalls).toHaveLength(0)
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
