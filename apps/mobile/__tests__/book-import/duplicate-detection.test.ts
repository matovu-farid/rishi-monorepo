/**
 * DAT-002 (#115): Mobile book-import must reject a second import of the
 * same file content. Previously every import minted a fresh UUID and
 * inserted a new row even when the user re-picked the same EPUB; the
 * library showed two rows pointing at the same content.
 *
 * Contract pinned here:
 *   - Before delegating to the shared service, `runImportWithService`
 *     hashes the source bytes and checks the books table for a row with
 *     the matching `fileHash`.
 *   - Hit → return `{ ok: false, stage: 'duplicate', error }` without
 *     touching the filesystem or the shared service.
 *   - Miss → proceed as before; the existing pipeline patches `fileHash`
 *     onto the row via the UploadPort.
 *   - The same gate runs in `importBookFromUrl` after the bytes are
 *     downloaded but BEFORE the per-book directory + tmp file are
 *     written, so a duplicate URL import doesn't leave an orphan dir.
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
let pickFileResult: { uri: string } | null = null
const createdDirs: string[] = []
const deletedDirs: string[] = []

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
  ;(FileCtor as unknown as { pickFileAsync: jest.Mock }).pickFileAsync = jest.fn(
    async () => pickFileResult,
  )

  const DirectoryCtor = jest.fn().mockImplementation((...parts: unknown[]) => {
    const segs = parts.map((p) =>
      typeof p === 'string' ? p : ((p as { uri?: string })?.uri ?? ''),
    )
    const uri = segs.filter(Boolean).join('/')
    return {
      uri,
      exists: true,
      create: jest.fn(() => {
        createdDirs.push(uri)
      }),
      delete: jest.fn(() => {
        deletedDirs.push(uri)
      }),
    }
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
  }
})

// rag/pipeline pulls in native modules. Not invoked here, but file-import
// re-exports it from the same module so we need to stub it.
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

// ── DB stub: stores rows keyed by fileHash so the duplicate query can find ──
// matches added by the test setup. We mock @/lib/db (used by file-import for
// the duplicate query) AND any drizzle-orm helpers the importer needs.
const dbState = {
  rows: new Map<string, Record<string, unknown>>(),
  hashLookups: 0,
}

function makeSelectStub(matchValue: unknown): {
  get: () => Record<string, unknown> | undefined
  all: () => Array<Record<string, unknown>>
} {
  dbState.hashLookups += 1
  // The where clause's value travels through our drizzle-orm `eq` mock,
  // which packages it as { col, val }. The file-import code calls
  // `.get()` so we only need to return the first match (or undefined).
  const hashStr =
    matchValue && typeof matchValue === 'object' && 'val' in (matchValue as object)
      ? String((matchValue as { val: unknown }).val)
      : ''
  const rows = Array.from(dbState.rows.values()).filter(
    (r) => String(r.fileHash) === hashStr,
  )
  return {
    get: () => rows[0],
    all: () => rows,
  }
}

jest.mock('@rishi/shared/schema', () => ({
  books: { id: 'id', fileHash: 'fileHash' },
}))

jest.mock('drizzle-orm', () => ({
  eq: jest.fn((col, val) => ({ col, val })),
  and: jest.fn((...args) => ({ and: args })),
}))

jest.mock('@/lib/db', () => ({
  db: {
    select: jest.fn(() => ({
      from: jest.fn(() => ({
        where: jest.fn((w: unknown) => makeSelectStub(w)),
      })),
    })),
  },
}))

// Stub the shared service factory so we can observe whether it was invoked
// (the duplicate gate must short-circuit BEFORE the service runs).
const serviceCalls = {
  factoryArgs: [] as Array<Record<string, unknown>>,
  importFromPath: [] as string[],
}

jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService: jest.fn(
    (opts: Record<string, unknown>) => {
      serviceCalls.factoryArgs.push(opts)
      return {
        importFromPath: jest.fn(async (uri: string) => {
          serviceCalls.importFromPath.push(uri)
          return {
            ok: true,
            bookId: opts.bookId,
            bookPath: `/docs/books/${String(opts.bookId)}/book.${String(opts.format)}`,
            format: opts.format,
          }
        }),
        indexBook: jest.fn(async () => undefined),
      }
    },
  ),
}))

// Hash function — returns a deterministic hash so the test can pre-populate
// dbState.rows with a matching row.
jest.mock('@/lib/sync/file-sync', () => ({
  hashBookFile: jest.fn(async () => 'duplicate-hash'),
}))

// Global fetch stub for URL import path.
const realFetch = global.fetch
const mockFetch = jest.fn()
beforeAll(() => {
  global.fetch = mockFetch as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = realFetch
})

import { importEpubFile, importBookFromUrl } from '@/lib/file-import'

function resetAll(): void {
  fakeFiles.clear()
  createdDirs.length = 0
  deletedDirs.length = 0
  pickFileResult = null
  dbState.rows.clear()
  dbState.hashLookups = 0
  serviceCalls.factoryArgs.length = 0
  serviceCalls.importFromPath.length = 0
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

// ────────────────────────────────────────────────────────────────────────────
// Picker-driven imports — duplicate gate
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-002 — picker import rejects duplicates by file hash', () => {
  beforeEach(resetAll)

  it('returns ok:false stage:duplicate when an existing book has the same fileHash', async () => {
    // Pre-populate as if a prior import wrote a row with the same content.
    dbState.rows.set('existing-1', {
      id: 'existing-1',
      title: 'Already imported',
      fileHash: 'duplicate-hash',
    })

    pickFileResult = { uri: '/Downloads/sample.epub' }

    const outcome = await importEpubFile()

    expect(outcome.ok).toBe(false)
    if (outcome.ok === false) {
      expect(outcome.stage).toBe('duplicate')
      expect(outcome.error).toMatch(/already/i)
    }
    // The shared service was never invoked — no copy, no row write.
    expect(serviceCalls.importFromPath).toHaveLength(0)
    expect(serviceCalls.factoryArgs).toHaveLength(0)
  })

  it('proceeds with the import when no existing row matches the hash', async () => {
    pickFileResult = { uri: '/Downloads/fresh.epub' }
    // dbState.rows is empty → hash query returns undefined.

    const outcome = await importEpubFile()

    expect(outcome.ok).toBe(true)
    // The shared service WAS invoked.
    expect(serviceCalls.importFromPath).toHaveLength(1)
  })
})

// ────────────────────────────────────────────────────────────────────────────
// URL import — duplicate gate must also not leave an orphan tmp dir
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-002 — URL import rejects duplicates by file hash', () => {
  beforeEach(resetAll)

  it('throws a duplicate error and removes the per-book directory it created', async () => {
    dbState.rows.set('existing-2', {
      id: 'existing-2',
      title: 'Existing URL import',
      fileHash: 'duplicate-hash',
    })

    mockFetch.mockResolvedValueOnce(
      downloadResponse({
        contentType: 'application/epub+zip',
        contentLength: '1000',
      }),
    )

    await expect(
      importBookFromUrl('https://example.com/lib/dup.epub'),
    ).rejects.toThrow(/duplicate|already/i)

    // The shared service was never invoked.
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })
})
