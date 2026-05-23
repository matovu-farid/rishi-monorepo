/**
 * DAT-011 (#123): a failed import must not leave a per-book directory
 * behind. Three failure surfaces are covered:
 *
 *   1. URL import — shared service returns ok:false (parse/save error)
 *      → the bookDir we created to stash the tmp file is removed.
 *   2. URL import — shared service THROWS an unexpected error
 *      → bookDir is still removed.
 *   3. URL import — duplicate-by-hash hit
 *      → bookDir is removed; the existing row is left untouched.
 *
 * The picker-driven path delegates dir creation to the shared service's
 * FsPort. When `copyBookToAppData` fails the FsPort itself is
 * responsible for not leaving a half-empty dir; this test isolates the
 * URL-import surface where file-import.ts owns the bookDir lifecycle.
 */

// ── Native fakes ────────────────────────────────────────────────────────────
type FakeFile = {
  uri: string
  exists: boolean
  write: jest.Mock
  bytes: jest.Mock
  base64: jest.Mock
  delete: jest.Mock
  copy: jest.Mock
}

type FakeDir = {
  uri: string
  exists: boolean
  create: jest.Mock
  delete: jest.Mock
}

const fakeFiles = new Map<string, FakeFile>()
const fakeDirs = new Map<string, FakeDir>()

function makeFakeFile(uri: string): FakeFile {
  const file: FakeFile = {
    uri,
    exists: true,
    write: jest.fn(),
    bytes: jest.fn(async () => new Uint8Array([1, 2, 3])),
    base64: jest.fn(async () => 'AAAA'),
    delete: jest.fn(() => {
      file.exists = false
    }),
    copy: jest.fn(),
  }
  return file
}

function makeFakeDir(uri: string): FakeDir {
  const dir: FakeDir = {
    uri,
    exists: true,
    create: jest.fn(),
    delete: jest.fn(() => {
      dir.exists = false
    }),
  }
  return dir
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
  ;(FileCtor as unknown as { pickFileAsync: jest.Mock }).pickFileAsync = jest.fn()

  const DirectoryCtor = jest.fn().mockImplementation((...parts: unknown[]) => {
    const segs = parts.map((p) =>
      typeof p === 'string' ? p : ((p as { uri?: string })?.uri ?? ''),
    )
    const uri = segs.filter(Boolean).join('/')
    if (!fakeDirs.has(uri)) {
      fakeDirs.set(uri, makeFakeDir(uri))
    }
    return fakeDirs.get(uri)!
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
  }
})

jest.mock('@/lib/rag/pipeline', () => ({ embedBook: jest.fn() }))
jest.mock('@/app/_layout', () => ({ __esModule: true, IS_E2E_TEST: false }))
jest.mock('@/lib/auth', () => ({
  __esModule: true,
  getSessionToken: jest.fn(async () => null),
}))
jest.mock('@/lib/file-import-index-gate', () => ({
  __esModule: true,
  shouldSkipIndexing: jest.fn(() => true),
}))

jest.mock('@rishi/shared/schema', () => ({
  books: { id: 'id', fileHash: 'fileHash' },
}))

jest.mock('drizzle-orm', () => ({
  eq: jest.fn((col, val) => ({ col, val })),
}))

const dbState = {
  rows: new Map<string, Record<string, unknown>>(),
}

jest.mock('@/lib/db', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: (w: unknown) => {
          const hashStr =
            w && typeof w === 'object' && 'val' in (w as object)
              ? String((w as { val: unknown }).val)
              : ''
          const matches = Array.from(dbState.rows.values()).filter(
            (r) => String(r.fileHash) === hashStr,
          )
          return {
            get: () => matches[0],
            all: () => matches,
          }
        },
      }),
    }),
  },
}))

jest.mock('@/lib/sync/file-sync', () => ({
  __esModule: true,
  hashBookFile: jest.fn(async () => 'hash-for-bytes'),
  uploadBookFile: jest.fn(),
  UploadLimitError: class extends Error {},
}))

// Adapter deps the FsPort doesn't touch, but the adapter module loads
// at import time. Keep the surface area tiny.
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
  deleteBookChunks: jest.fn(),
}))
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: jest.fn(),
}))
jest.mock('@rishi/shared/formats/mobi', () => ({
  extractMobiCover: jest.fn(),
}))

// Service factory — scriptable per-test.
type ServiceResult =
  | { ok: true; bookId: string; bookPath: string; format: string }
  | { ok: false; stage: string; error: string }

let serviceBehaviour:
  | { kind: 'resolve'; result: ServiceResult }
  | { kind: 'throw'; err: Error } = {
  kind: 'resolve',
  result: {
    ok: true,
    bookId: 'service-bookid',
    bookPath: '/docs/books/service-bookid/book.epub',
    format: 'epub',
  },
}

const serviceCalls = {
  importFromPath: [] as string[],
}

jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService: jest.fn(() => ({
    importFromPath: jest.fn(async (uri: string) => {
      serviceCalls.importFromPath.push(uri)
      if (serviceBehaviour.kind === 'throw') throw serviceBehaviour.err
      return serviceBehaviour.result
    }),
    indexBook: jest.fn(async () => undefined),
  })),
}))

const realFetch = global.fetch
const mockFetch = jest.fn()
beforeAll(() => {
  global.fetch = mockFetch as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = realFetch
})

import { importBookFromUrl } from '@/lib/file-import'

function resetAll(): void {
  fakeFiles.clear()
  fakeDirs.clear()
  dbState.rows.clear()
  serviceCalls.importFromPath.length = 0
  serviceBehaviour = {
    kind: 'resolve',
    result: {
      ok: true,
      bookId: 'service-bookid',
      bookPath: '/docs/books/service-bookid/book.epub',
      format: 'epub',
    },
  }
  mockFetch.mockReset()
  jest.clearAllMocks()
}

function downloadResponse(opts: {
  ok?: boolean
  status?: number
  contentType?: string | null
  contentLength?: string | null
}): Response {
  return {
    ok: opts.ok ?? true,
    status: opts.status ?? 200,
    statusText: 'OK',
    headers: {
      get: (k: string) => {
        if (k.toLowerCase() === 'content-type') return opts.contentType ?? null
        if (k.toLowerCase() === 'content-length') return opts.contentLength ?? null
        return null
      },
    },
    arrayBuffer: async () => new ArrayBuffer(4),
  } as unknown as Response
}

function findBookDir(): FakeDir | undefined {
  // The dir we expect to be cleaned up looks like /docs/books/<uuid>.
  return Array.from(fakeDirs.values()).find(
    (d) => d.uri.startsWith('/docs/books/') && d.uri !== '/docs/books',
  )
}

// ── FsPort cleanup test (picker path) ──────────────────────────────────────
//
// The picker path drives `createMobileFsPort.copyBookToAppData` directly via
// the shared service. We isolate that port and force the copy step to throw
// to pin the dir-cleanup contract independently from the URL flow above.

describe('DAT-011 — FsPort cleans up the per-book dir when copy throws', () => {
  // The other test file ships a full adapter-isolated mock setup; here we
  // re-import the port directly and rely on the expo-file-system mock
  // already configured at the top of this file. We tag the throw to a
  // specific source URI so other tests aren't affected.
  it('removes the bookDir when the source copy throws', async () => {
    resetAll()
    // Pre-create the source file fake and make its `copy` method throw.
    const src = '/Downloads/will-fail.epub'
    const sourceFile = makeFakeFile(src)
    sourceFile.copy = jest.fn(() => {
      throw new Error('ENOSPC: out of disk')
    })
    fakeFiles.set(src, sourceFile)

    // Import the port lazily so the test environment's expo-file-system
    // mock is in scope.
    const { createMobileFsPort } = await import('@/lib/book-import/adapters')
    const port = createMobileFsPort({ bookId: 'b-fs-fail', format: 'epub' })

    await expect(port.copyBookToAppData(src)).rejects.toThrow(/ENOSPC/)

    // The bookDir we expect cleanup on:
    const bookDir = fakeDirs.get('/docs/books/b-fs-fail')
    expect(bookDir).toBeDefined()
    expect(bookDir!.delete).toHaveBeenCalledTimes(1)
  })
})

describe('DAT-011 — URL import cleans up the per-book directory on failure', () => {
  beforeEach(resetAll)

  it('removes the bookDir when the shared service returns ok:false', async () => {
    serviceBehaviour = {
      kind: 'resolve',
      result: { ok: false, stage: 'parse', error: 'corrupt epub' },
    }
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await expect(
      importBookFromUrl('https://example.com/lib/broken.epub'),
    ).rejects.toThrow(/Import failed/)

    const bookDir = findBookDir()
    expect(bookDir).toBeDefined()
    expect(bookDir!.delete).toHaveBeenCalledTimes(1)
  })

  it('removes the bookDir when the shared service THROWS unexpectedly', async () => {
    serviceBehaviour = { kind: 'throw', err: new Error('unexpected boom') }
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await expect(
      importBookFromUrl('https://example.com/lib/boom.epub'),
    ).rejects.toThrow(/unexpected boom/)

    const bookDir = findBookDir()
    expect(bookDir).toBeDefined()
    expect(bookDir!.delete).toHaveBeenCalledTimes(1)
  })

  it('removes the bookDir on a duplicate-by-hash hit', async () => {
    dbState.rows.set('existing', {
      id: 'existing',
      fileHash: 'hash-for-bytes',
    })

    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await expect(
      importBookFromUrl('https://example.com/lib/dup.epub'),
    ).rejects.toThrow()

    const bookDir = findBookDir()
    expect(bookDir).toBeDefined()
    expect(bookDir!.delete).toHaveBeenCalledTimes(1)
  })

  it('does NOT delete the bookDir on a successful import (sanity)', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await importBookFromUrl('https://example.com/lib/good.epub')

    const bookDir = findBookDir()
    expect(bookDir).toBeDefined()
    expect(bookDir!.delete).not.toHaveBeenCalled()
  })
})
