/**
 * CG05 — `importBookFromUrl` URL import coverage for the mobile app.
 *
 * The function (lib/file-import.ts:205) downloads a book from an HTTP(S) URL,
 * stashes the bytes in a per-book tmp file, then runs the shared book-import
 * service. The coverage gap calls for:
 *
 *  - HEAD-request failure on the target URL (path-format hint missing)
 *  - Non-2xx response on the actual GET
 *  - Bad content-type (e.g., HTML returned instead of a book file)
 *  - Happy path (no existing coverage — added here)
 *
 * Plus an invalid-URL guard from the production code's own preconditions.
 *
 * Strategy: mock `createMobileBookImportService` and friends at the JS boundary
 * so we exercise the real URL-handling branches of `importBookFromUrl` without
 * pulling in expo-sqlite / drizzle.
 */

// ────────────────────────────────────────────────────────────────────────────
// Native module + DB stubs
// ────────────────────────────────────────────────────────────────────────────

type FakeFile = {
  uri: string
  exists: boolean
  write: jest.Mock
  bytes: jest.Mock
  delete: jest.Mock
}

const fakeFiles = new Map<string, FakeFile>()

function makeFakeFile(uri: string): FakeFile {
  const file: FakeFile = {
    uri,
    exists: true,
    write: jest.fn(),
    bytes: jest.fn(async () => new Uint8Array([1, 2, 3])),
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
    }
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
  }
})

// rag/pipeline pulls in native modules. The URL importer only re-exports
// `embedBook` from there; never invokes it.
jest.mock('@/lib/rag/pipeline', () => ({
  embedBook: jest.fn(),
}))

// app/_layout transitively pulls in @react-navigation/native which Jest can't
// parse out of the box. We only need the IS_E2E_TEST flag.
jest.mock('@/app/_layout', () => ({
  __esModule: true,
  IS_E2E_TEST: false,
}))

jest.mock('@/lib/auth', () => ({
  __esModule: true,
  getSessionToken: jest.fn(async () => null),
}))

jest.mock('@/lib/file-import-index-gate', () => ({
  __esModule: true,
  shouldSkipIndexing: jest.fn(() => true),
}))

// DAT-002 (#115): file-import now queries the books table for a
// matching file hash before delegating to the shared service. Stub the
// DB + drizzle helpers so the query returns "no match" by default.
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
        where: () => ({
          get: () => undefined,
          all: () => [],
        }),
      }),
    }),
  },
}))

jest.mock('@/lib/sync/file-sync', () => ({
  __esModule: true,
  hashBookFile: jest.fn(async () => 'fresh-hash'),
}))

// ────────────────────────────────────────────────────────────────────────────
// Mock the shared book-import service factory.
// We capture what the URL import passes to `importFromPath` so we can assert
// the format-detection branches; the service result is scripted per-test.
// ────────────────────────────────────────────────────────────────────────────

type ImportFromPathResult =
  | { ok: true; bookId: string; bookPath: string; format: string }
  | { ok: false; stage: string; error: string }

const serviceCalls = {
  factoryArgs: [] as Array<{ bookId: string; format: string; title: string; author?: string }>,
  importFromPath: [] as string[],
  indexBook: [] as Array<{ bookId: string; bookPath: string; format: string }>,
}

let importResult: ImportFromPathResult = {
  ok: true,
  bookId: 'mocked-book-id',
  bookPath: '/docs/books/mocked-book-id/book.epub',
  format: 'epub',
}

jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService: jest.fn((opts: { bookId: string; format: string; title: string; author?: string }) => {
    serviceCalls.factoryArgs.push(opts)
    return {
      importFromPath: jest.fn(async (uri: string) => {
        serviceCalls.importFromPath.push(uri)
        return importResult
      }),
      indexBook: jest.fn(async (bookId: string, _chunks: unknown, bookPath: string, format: string) => {
        serviceCalls.indexBook.push({ bookId, bookPath, format })
      }),
    }
  }),
}))

// ────────────────────────────────────────────────────────────────────────────
// Global fetch stub
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

import { importBookFromUrl } from '@/lib/file-import'

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

function downloadResponse(opts: {
  ok?: boolean
  status?: number
  statusText?: string
  contentType?: string | null
}): Response {
  return {
    ok: opts.ok ?? true,
    status: opts.status ?? 200,
    statusText: opts.statusText ?? 'OK',
    headers: {
      get: (k: string) =>
        k.toLowerCase() === 'content-type' ? (opts.contentType ?? null) : null,
    },
    arrayBuffer: async () => new ArrayBuffer(4),
  } as unknown as Response
}

function headResponse(contentType: string | null): Response {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    headers: {
      get: (k: string) =>
        k.toLowerCase() === 'content-type' ? contentType : null,
    },
  } as unknown as Response
}

function resetAll(): void {
  fakeFiles.clear()
  mockFetch.mockReset()
  serviceCalls.factoryArgs.length = 0
  serviceCalls.importFromPath.length = 0
  serviceCalls.indexBook.length = 0
  importResult = {
    ok: true,
    bookId: 'mocked-book-id',
    bookPath: '/docs/books/mocked-book-id/book.epub',
    format: 'epub',
  }
  jest.clearAllMocks()
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

describe('importBookFromUrl — invalid URL guard', () => {
  beforeEach(() => resetAll())

  it('rejects URLs that do not begin with http:// or https://', async () => {
    await expect(importBookFromUrl('ftp://example.com/book.epub')).rejects.toThrow(
      /Invalid URL/,
    )
    // Did not even attempt a network call.
    expect(mockFetch).not.toHaveBeenCalled()
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('rejects empty strings', async () => {
    await expect(importBookFromUrl('')).rejects.toThrow(/Invalid URL/)
    expect(mockFetch).not.toHaveBeenCalled()
  })
})

describe('importBookFromUrl — HEAD-request failure', () => {
  beforeEach(() => resetAll())

  it('falls back to GET content-type sniff when HEAD throws on a path-extension-less URL', async () => {
    // URL has no .epub/.pdf hint, so the importer goes through the HEAD branch.
    // HEAD rejects (DNS error, CORS, etc.) — the importer must swallow the
    // throw and fall through to the GET.
    mockFetch
      .mockRejectedValueOnce(new Error('Network unreachable'))
      .mockResolvedValueOnce(
        downloadResponse({ contentType: 'application/epub+zip' }),
      )

    const book = await importBookFromUrl('https://example.com/download/book')

    // HEAD attempted; GET attempted; service invoked with the sniffed format.
    expect(mockFetch).toHaveBeenCalledTimes(2)
    expect((mockFetch.mock.calls[0][1] as RequestInit | undefined)?.method).toBe('HEAD')
    expect(mockFetch.mock.calls[1][1]).toBeUndefined() // plain GET
    expect(serviceCalls.factoryArgs[0]?.format).toBe('epub')
    expect(book.format).toBe('epub')
  })

  it('throws unsupported-format when HEAD fails AND GET has no usable content-type', async () => {
    mockFetch
      .mockRejectedValueOnce(new Error('Network unreachable'))
      .mockResolvedValueOnce(downloadResponse({ contentType: null }))

    await expect(
      importBookFromUrl('https://example.com/mystery-blob'),
    ).rejects.toThrow(/Unsupported format/)

    // Service was never invoked.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })
})

describe('importBookFromUrl — non-2xx download (P1-AD)', () => {
  beforeEach(() => resetAll())

  it('throws "We couldn\'t find that file" when the GET returns 404 Not Found', async () => {
    // Path extension is .epub so HEAD is skipped — go straight to GET.
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ ok: false, status: 404, statusText: 'Not Found' }),
    )

    await expect(
      importBookFromUrl('https://example.com/missing.epub'),
    ).rejects.toThrow(/We couldn't find that file/)

    // No tmp file was written, no service call.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('throws "URL requires permission" when the GET returns 401 Unauthorized', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ ok: false, status: 401, statusText: 'Unauthorized' }),
    )

    await expect(
      importBookFromUrl('https://example.com/private.epub'),
    ).rejects.toThrow(/URL requires permission/)

    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('throws "URL requires permission" when the GET returns 403 Forbidden', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ ok: false, status: 403, statusText: 'Forbidden' }),
    )

    await expect(
      importBookFromUrl('https://example.com/forbidden.epub'),
    ).rejects.toThrow(/URL requires permission/)

    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('throws "Server refused download" when the GET returns 500 Internal Server Error', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ ok: false, status: 500, statusText: 'Internal Server Error' }),
    )

    await expect(
      importBookFromUrl('https://example.com/book.pdf'),
    ).rejects.toThrow(/Server refused download/)

    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('throws "Server refused download" on other non-2xx statuses (e.g. 502)', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({ ok: false, status: 502, statusText: 'Bad Gateway' }),
    )

    await expect(
      importBookFromUrl('https://example.com/book.pdf'),
    ).rejects.toThrow(/Server refused download/)

    expect(serviceCalls.importFromPath).toHaveLength(0)
  })
})

describe('importBookFromUrl — bad content-type', () => {
  beforeEach(() => resetAll())

  it('throws unsupported-format when server returns text/html instead of a book', async () => {
    // URL hint is absent → HEAD returns HTML → GET returns HTML.
    mockFetch
      .mockResolvedValueOnce(headResponse('text/html; charset=utf-8'))
      .mockResolvedValueOnce(downloadResponse({ contentType: 'text/html; charset=utf-8' }))

    await expect(
      importBookFromUrl('https://example.com/some/landing-page'),
    ).rejects.toThrow(/Unsupported format/)

    // We DID consume the body (the importer reaches arrayBuffer() before
    // re-checking content-type), but we never delegated to the service.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('throws unsupported-format on application/json', async () => {
    mockFetch
      .mockResolvedValueOnce(headResponse('application/json'))
      .mockResolvedValueOnce(downloadResponse({ contentType: 'application/json' }))

    await expect(
      importBookFromUrl('https://api.example.com/v1/books/123'),
    ).rejects.toThrow(/Unsupported format/)
  })
})

describe('importBookFromUrl — happy paths', () => {
  beforeEach(() => resetAll())

  it('uses path-extension format detection (.epub) and skips the HEAD probe', async () => {
    importResult = {
      ok: true,
      bookId: 'mocked-book-id',
      bookPath: '/docs/books/mocked-book-id/book.epub',
      format: 'epub',
    }

    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    const book = await importBookFromUrl(
      'https://example.com/library/Pride%20%26%20Prejudice.epub',
    )

    // Only ONE network call — straight to GET.
    expect(mockFetch).toHaveBeenCalledTimes(1)
    expect((mockFetch.mock.calls[0][1] as RequestInit | undefined)?.method).toBeUndefined()

    // Service was invoked with format=epub and the URL's decoded title.
    expect(serviceCalls.factoryArgs).toHaveLength(1)
    expect(serviceCalls.factoryArgs[0].format).toBe('epub')
    expect(serviceCalls.factoryArgs[0].title).toBe('Pride & Prejudice')

    // importFromPath was called with the tmp file URI inside the book dir.
    expect(serviceCalls.importFromPath).toHaveLength(1)
    expect(serviceCalls.importFromPath[0]).toMatch(/tmp\.epub$/)

    // Book row returned to the caller.
    expect(book.format).toBe('epub')
    expect(book.title).toBe('Pride & Prejudice')
  })

  it('falls back to HEAD content-type when the URL has no extension', async () => {
    importResult = {
      ok: true,
      bookId: 'mocked-book-id',
      bookPath: '/docs/books/mocked-book-id/book.pdf',
      format: 'pdf',
    }

    mockFetch
      .mockResolvedValueOnce(headResponse('application/pdf'))
      .mockResolvedValueOnce(downloadResponse({ contentType: 'application/pdf' }))

    const book = await importBookFromUrl('https://arxiv.org/abs/2401.12345')

    expect(mockFetch).toHaveBeenCalledTimes(2)
    expect((mockFetch.mock.calls[0][1] as RequestInit | undefined)?.method).toBe('HEAD')
    expect(serviceCalls.factoryArgs[0].format).toBe('pdf')
    expect(book.format).toBe('pdf')
  })

  it('cleans up the tmp file after a successful import (best-effort delete)', async () => {
    importResult = {
      ok: true,
      bookId: 'mocked-book-id',
      bookPath: '/docs/books/mocked-book-id/book.epub',
      format: 'epub',
    }

    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await importBookFromUrl('https://example.com/lib/a.epub')

    // Locate the tmp file the importer wrote bytes into.
    const tmp = Array.from(fakeFiles.values()).find((f) => f.uri.endsWith('tmp.epub'))
    expect(tmp).toBeDefined()
    expect(tmp!.write).toHaveBeenCalledTimes(1)
    expect(tmp!.delete).toHaveBeenCalledTimes(1)
  })

  it('surfaces a clear error when the shared service reports failure', async () => {
    importResult = { ok: false, stage: 'parse', error: 'corrupt epub' }

    mockFetch.mockResolvedValueOnce(
      downloadResponse({ contentType: 'application/epub+zip' }),
    )

    await expect(
      importBookFromUrl('https://example.com/lib/broken.epub'),
    ).rejects.toThrow(/Import failed/)
  })
})
