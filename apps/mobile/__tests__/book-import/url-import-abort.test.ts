/**
 * DAT-017 (#129): URL imports must be cancellable. Previously, dismissing
 * `UrlImportSheet` mid-download did nothing — `importBookFromUrl`
 * called `fetch(url)` with no signal, so a 500 MB download kept
 * buffering in the background until completion. On flaky networks
 * users frequently re-opened the sheet to retry, leading to a stack
 * of zombie fetches.
 *
 * Contract pinned here:
 *   - `importBookFromUrl(url, { signal })` accepts an optional
 *     AbortSignal and forwards it to BOTH the HEAD probe and the GET.
 *   - Aborting AFTER the GET returns but BEFORE arrayBuffer() resolves
 *     short-circuits to a rejection without touching the filesystem or
 *     calling the shared service.
 *   - The thrown error is an AbortError (or carries the standard
 *     `.name === 'AbortError'`).
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

const fakeFiles = new Map<string, FakeFile>()

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
    return {
      uri,
      exists: true,
      create: jest.fn(),
      delete: jest.fn(),
    }
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
jest.mock('@/lib/db', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: () => ({ get: () => undefined, all: () => [] }),
      }),
    }),
  },
}))
jest.mock('@/lib/sync/file-sync', () => ({
  __esModule: true,
  hashBookFile: jest.fn(async () => 'fresh-hash'),
}))

const serviceCalls = {
  importFromPath: [] as string[],
}
jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService: jest.fn(() => ({
    importFromPath: jest.fn(async (uri: string) => {
      serviceCalls.importFromPath.push(uri)
      return {
        ok: true,
        bookId: 'mock-id',
        bookPath: `/docs/books/mock-id/book.epub`,
        format: 'epub',
      }
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
  serviceCalls.importFromPath.length = 0
  mockFetch.mockReset()
  jest.clearAllMocks()
}

function makeAbortError(): Error {
  const err = new Error('The operation was aborted')
  err.name = 'AbortError'
  return err
}

describe('DAT-017 — importBookFromUrl is cancellable via AbortSignal', () => {
  beforeEach(resetAll)

  it('forwards the signal to fetch and rejects with AbortError when aborted before GET resolves', async () => {
    const ctl = new AbortController()
    // The GET fetch returns a promise that respects the controller.
    mockFetch.mockImplementationOnce(
      (_url: string, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          if (init?.signal?.aborted) {
            return reject(makeAbortError())
          }
          init?.signal?.addEventListener('abort', () => reject(makeAbortError()))
        }),
    )

    const promise = importBookFromUrl(
      'https://example.com/big.epub',
      { signal: ctl.signal },
    )

    // Abort while the body is still buffering.
    ctl.abort()

    await expect(promise).rejects.toMatchObject({ name: 'AbortError' })

    // The fetch was called with the controller's signal.
    expect(mockFetch).toHaveBeenCalledTimes(1)
    const init = mockFetch.mock.calls[0][1] as RequestInit | undefined
    expect(init?.signal).toBe(ctl.signal)

    // We did not delegate to the shared service.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('forwards the signal to the HEAD probe on extension-less URLs', async () => {
    const ctl = new AbortController()
    // HEAD never resolves; rely on abort to reject it.
    mockFetch.mockImplementationOnce(
      (_url: string, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(makeAbortError()))
        }),
    )

    const promise = importBookFromUrl(
      'https://example.com/no-ext',
      { signal: ctl.signal },
    )

    ctl.abort()
    await expect(promise).rejects.toBeDefined()

    // HEAD's init.signal was the controller's signal.
    const headInit = mockFetch.mock.calls[0][1] as RequestInit
    expect(headInit.method).toBe('HEAD')
    expect(headInit.signal).toBe(ctl.signal)
  })

  it('still works (no abort) when no signal is supplied — backwards compatibility', async () => {
    mockFetch.mockResolvedValueOnce({
      ok: true,
      status: 200,
      statusText: 'OK',
      headers: {
        get: (k: string) =>
          k.toLowerCase() === 'content-type' ? 'application/epub+zip' : null,
      },
      arrayBuffer: async () => new ArrayBuffer(4),
    } as unknown as Response)

    const book = await importBookFromUrl('https://example.com/edge.epub')
    expect(book.format).toBe('epub')
  })
})
