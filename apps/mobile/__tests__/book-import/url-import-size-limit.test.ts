/**
 * DAT-012 (#124): URL import must reject downloads that overflow device
 * memory. Previously the importer fetched the full body unconditionally
 * via `downloadRes.arrayBuffer()`, so a 2 GB file would OOM the JS VM
 * (especially on Android where the heap cap is lower).
 *
 * Contract pinned here:
 *   - The importer consults `content-length` (HEAD first, then the GET
 *     response itself as a fallback) before reading bytes.
 *   - When `content-length` exceeds 500 MB, the importer throws with
 *     a user-facing message that mentions the size limit. The body is
 *     never consumed.
 *   - When `content-length` is missing or malformed, the importer
 *     proceeds (we can't enforce a limit we can't see; the existing
 *     pipeline still surfaces parse / save errors downstream).
 */

const FIVE_HUNDRED_MB = 500 * 1024 * 1024
const SIX_HUNDRED_MB = 600 * 1024 * 1024

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
    bytes: jest.fn(async () => new Uint8Array([1])),
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

function headResponse(opts: {
  contentType?: string | null
  contentLength?: string | null
}): Response {
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    headers: {
      get: (k: string) => {
        if (k.toLowerCase() === 'content-type') return opts.contentType ?? null
        if (k.toLowerCase() === 'content-length') return opts.contentLength ?? null
        return null
      },
    },
  } as unknown as Response
}

function downloadResponse(opts: {
  ok?: boolean
  status?: number
  contentType?: string | null
  contentLength?: string | null
  arrayBufferImpl?: () => Promise<ArrayBuffer>
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
    arrayBuffer:
      opts.arrayBufferImpl ?? (async () => new ArrayBuffer(4)),
  } as unknown as Response
}

describe('DAT-012 — URL import enforces a 500 MB Content-Length limit', () => {
  beforeEach(resetAll)

  it('rejects when the HEAD response advertises content-length > 500 MB', async () => {
    // First call is the HEAD that file-import uses for format detection on
    // extension-less URLs. The path here has .epub, so the importer skips
    // HEAD entirely. We exercise the GET-side Content-Length check.
    mockFetch.mockResolvedValueOnce(
      downloadResponse({
        contentType: 'application/epub+zip',
        contentLength: String(SIX_HUNDRED_MB),
      }),
    )

    await expect(
      importBookFromUrl('https://example.com/huge.epub'),
    ).rejects.toThrow(/too large|size limit|500\s*MB/i)

    // We should NOT have invoked the shared service.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('rejects via HEAD content-length when the URL has no path extension', async () => {
    // No extension → HEAD probe runs. Even though HEAD's content-type
    // identifies the file, the size header alone is enough to reject.
    mockFetch
      .mockResolvedValueOnce(
        headResponse({
          contentType: 'application/pdf',
          contentLength: String(SIX_HUNDRED_MB),
        }),
      )

    await expect(
      importBookFromUrl('https://example.com/big/document'),
    ).rejects.toThrow(/too large|size limit|500\s*MB/i)

    // Only the HEAD ran; the GET was short-circuited.
    expect(mockFetch).toHaveBeenCalledTimes(1)
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })

  it('proceeds when content-length is exactly at the 500 MB limit', async () => {
    // The check rejects ABOVE the limit (>), not AT.
    mockFetch
      .mockResolvedValueOnce(
        downloadResponse({
          contentType: 'application/epub+zip',
          contentLength: String(FIVE_HUNDRED_MB),
        }),
      )

    const book = await importBookFromUrl('https://example.com/edge.epub')
    expect(book.format).toBe('epub')
    expect(serviceCalls.importFromPath).toHaveLength(1)
  })

  it('proceeds when content-length is missing', async () => {
    // No content-length → we can't enforce; let it through.
    mockFetch.mockResolvedValueOnce(
      downloadResponse({
        contentType: 'application/epub+zip',
        contentLength: null,
      }),
    )

    const book = await importBookFromUrl('https://example.com/unknown.epub')
    expect(book.format).toBe('epub')
  })

  it('proceeds when content-length is non-numeric garbage', async () => {
    mockFetch.mockResolvedValueOnce(
      downloadResponse({
        contentType: 'application/epub+zip',
        contentLength: 'not-a-number',
      }),
    )

    const book = await importBookFromUrl('https://example.com/garbage.epub')
    expect(book.format).toBe('epub')
  })
})
