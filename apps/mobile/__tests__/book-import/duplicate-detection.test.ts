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

type EqClause = { col: string; val: unknown }
type AndClause = { and: Array<EqClause | AndClause> }

function flattenEqs(clause: unknown): EqClause[] {
  if (!clause || typeof clause !== 'object') return []
  if ('and' in (clause as Record<string, unknown>)) {
    return (clause as AndClause).and.flatMap(flattenEqs)
  }
  if ('col' in (clause as Record<string, unknown>)) {
    return [clause as EqClause]
  }
  return []
}

function makeSelectStub(matchValue: unknown): {
  get: () => Record<string, unknown> | undefined
  all: () => Array<Record<string, unknown>>
} {
  dbState.hashLookups += 1
  // The where clause may be a single `eq(...)` or an `and(eq(...), eq(...))`.
  // Flatten both shapes into a list of {col, val} predicates and apply them
  // all so soft-deleted rows can be filtered out (DAT-002: soft-delete +
  // re-import regression).
  const predicates = flattenEqs(matchValue)
  let rows = Array.from(dbState.rows.values())
  for (const p of predicates) {
    rows = rows.filter((r) => {
      const left = r[String(p.col)]
      // Allow the soft-delete filter to match rows that don't carry an
      // explicit `isDeleted` field by treating "undefined" as "false".
      if (left === undefined && p.col === 'isDeleted') return p.val === false
      return left === p.val
    })
  }
  return {
    get: () => rows[0],
    all: () => rows,
  }
}

jest.mock('@rishi/shared/schema', () => ({
  books: { id: 'id', fileHash: 'fileHash', isDeleted: 'isDeleted' },
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

import { importBookFile } from '@/lib/file-import'

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

    const outcome = await importBookFile()

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

    const outcome = await importBookFile()

    expect(outcome.ok).toBe(true)
    // The shared service WAS invoked.
    expect(serviceCalls.importFromPath).toHaveLength(1)
  })
})

// ────────────────────────────────────────────────────────────────────────────
// URL import — duplicate gate must also not leave an orphan tmp dir
// ────────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────────
// DAT-002 follow-up: soft-deleted books MUST be re-importable.
//
// PR #207 review (https://github.com/matovu-farid/rishi-monorepo/pull/207#pullrequestreview-4350414906)
// caught that the original duplicate gate matched on `fileHash` only, with
// no `isDeleted` predicate. Soft-deleting a book and then re-importing the
// same file got permanently rejected as a duplicate — no recovery short of
// manual SQL. The fix adds `AND isDeleted = false` to the SELECT so a
// soft-deleted row no longer blocks a fresh import.
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-002 — soft-deleted books are re-importable', () => {
  beforeEach(resetAll)

  it('allows re-import when the matching-hash row is soft-deleted', async () => {
    // A previous import wrote this row and it was later soft-deleted.
    dbState.rows.set('soft-deleted-1', {
      id: 'soft-deleted-1',
      title: 'Removed from library',
      fileHash: 'duplicate-hash',
      isDeleted: true,
    })

    pickFileResult = { uri: '/Downloads/coming-back.epub' }

    const outcome = await importBookFile()

    // The duplicate gate must NOT short-circuit when the only matching
    // row is soft-deleted; the import must proceed all the way through
    // the shared service.
    expect(outcome.ok).toBe(true)
    expect(serviceCalls.importFromPath).toHaveLength(1)
  })

  it('still rejects when a live (non-deleted) row exists alongside a soft-deleted one', async () => {
    dbState.rows.set('soft-deleted-2', {
      id: 'soft-deleted-2',
      title: 'Older removed copy',
      fileHash: 'duplicate-hash',
      isDeleted: true,
    })
    dbState.rows.set('live-2', {
      id: 'live-2',
      title: 'Current copy',
      fileHash: 'duplicate-hash',
      isDeleted: false,
    })

    pickFileResult = { uri: '/Downloads/coming-back.epub' }

    const outcome = await importBookFile()

    expect(outcome.ok).toBe(false)
    if (outcome.ok === false) {
      expect(outcome.stage).toBe('duplicate')
    }
    expect(serviceCalls.importFromPath).toHaveLength(0)
  })
})
