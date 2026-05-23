// Type the mocks loosely so the assertion helpers (`.calls[0][0] as string`,
// `.calls[0][1] as unknown[]`) compile even when jest can't infer arg tuples.
// The cast funnels them through `unknown` first to satisfy TS's no-overlap
// rule for unrelated tuple/string conversions.
const mockExecSync = jest.fn() as unknown as jest.Mock<unknown, unknown[]>
const mockRunSync = jest.fn(() => ({ lastInsertRowId: 42 })) as unknown as jest.Mock<
  { lastInsertRowId: number },
  unknown[]
>
const mockGetAllSync = jest.fn(() => [] as unknown[]) as unknown as jest.Mock<
  unknown[],
  unknown[]
>

// expo-sqlite is shipped as ESM and tsc-jest can't parse the published
// `export * from …` source. Stub the module before any source-of-truth
// import pulls it transitively (vector-store imports it for the bundled
// extensions surface). This mirrors how other __tests__ stub native
// boundary modules.
jest.mock('expo-sqlite', () => ({
  bundledExtensions: {
    'sqlite-vec': { libPath: '/fake/path/libsqlite-vec.dylib', entryPoint: 'sqlite3_vec_init' },
  },
  openDatabaseSync: jest.fn(),
}))

jest.mock('@/lib/db', () => ({
  rawDb: {
    loadExtensionSync: jest.fn(),
    execSync: mockExecSync,
    runSync: mockRunSync,
    getAllSync: mockGetAllSync,
  },
}))

import {
  initVectorExtension,
  ensureChunkTables,
  insertChunkWithVector,
  searchSimilarChunks,
  isBookEmbedded,
  deleteBookChunks,
} from '@/lib/rag/vector-store'
import { rawDb } from '@/lib/db'

beforeEach(() => {
  jest.clearAllMocks()
  mockRunSync.mockReturnValue({ lastInsertRowId: 42 })
  mockGetAllSync.mockReturnValue([])
})

describe('initVectorExtension', () => {
  it('calls loadExtensionSync with vec0', () => {
    initVectorExtension()
    expect(rawDb.loadExtensionSync).toHaveBeenCalledWith('vec0')
  })
})

describe('ensureChunkTables', () => {
  it('creates chunks table and chunk_vectors vec0 virtual table', () => {
    ensureChunkTables()
    expect(mockExecSync).toHaveBeenCalledTimes(2)
    const firstCall = mockExecSync.mock.calls[0][0] as string
    const secondCall = mockExecSync.mock.calls[1][0] as string
    expect(firstCall).toContain('CREATE TABLE IF NOT EXISTS chunks')
    expect(firstCall).toContain('book_id')
    expect(firstCall).toContain('chunk_index')
    expect(firstCall).toContain('text')
    expect(firstCall).toContain('chapter')
    expect(firstCall).toContain('created_at')
    expect(secondCall).toContain('CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vectors')
    expect(secondCall).toContain('USING vec0')
    expect(secondCall).toContain('float[384]')
  })
})

describe('insertChunkWithVector', () => {
  it('calls runSync twice (once for chunks INSERT, once for chunk_vectors INSERT)', () => {
    const embedding = new Array(384).fill(0.1)
    insertChunkWithVector('chunk-1', 'book-1', 0, 'hello', 'Ch1', embedding)
    expect(mockRunSync).toHaveBeenCalledTimes(2)
    const firstCall = mockRunSync.mock.calls[0][0] as string
    const secondCall = mockRunSync.mock.calls[1][0] as string
    expect(firstCall).toContain('INSERT INTO chunks')
    expect(secondCall).toContain('INSERT INTO chunk_vectors')
    // Second call should use lastInsertRowId from first call
    expect(mockRunSync.mock.calls[1][1]).toEqual(
      expect.arrayContaining([42])
    )
  })

  // DAT-006 (#119): vector tables are created with `vec0(embedding float[384])`.
  // If upstream embedder ever returns a wrong-dimensioned vector (e.g. server
  // upgrades to 768-dim, a 0-dim sentinel slips through, NaN entries arrive),
  // sqlite-vec stores garbage and the KNN search silently degrades. We enforce
  // the dimension AND the value shape at the JS boundary so the throw is
  // catchable before persisting either row.
  describe('DAT-006 — wrong-dimension input is rejected', () => {
    it('throws when embedding length is 768 (server upgraded to a different model)', () => {
      const embedding = new Array(768).fill(0.1)
      expect(() =>
        insertChunkWithVector('chunk-x', 'book-1', 0, 'hello', null, embedding),
      ).toThrow(/dimension/i)
      // No partial writes — neither the chunks row nor the vector row should
      // have been inserted.
      expect(mockRunSync).not.toHaveBeenCalled()
    })

    it('throws when embedding length is 0', () => {
      expect(() =>
        insertChunkWithVector('chunk-x', 'book-1', 0, 'hello', null, []),
      ).toThrow(/dimension/i)
      expect(mockRunSync).not.toHaveBeenCalled()
    })

    it('throws when embedding length is 383 (off-by-one)', () => {
      const embedding = new Array(383).fill(0.1)
      expect(() =>
        insertChunkWithVector('chunk-x', 'book-1', 0, 'hello', null, embedding),
      ).toThrow(/dimension/i)
      expect(mockRunSync).not.toHaveBeenCalled()
    })

    it('throws when embedding contains NaN', () => {
      const embedding = new Array(384).fill(0.1)
      embedding[10] = Number.NaN
      expect(() =>
        insertChunkWithVector('chunk-x', 'book-1', 0, 'hello', null, embedding),
      ).toThrow(/finite|NaN/i)
      expect(mockRunSync).not.toHaveBeenCalled()
    })
  })
})

describe('searchSimilarChunks', () => {
  it('calls getAllSync with a query containing MATCH and book_id filter', () => {
    const queryEmbedding = new Array(384).fill(0.2)
    mockGetAllSync.mockReturnValue([
      { id: 'c1', text: 'hello', chapter: 'Ch1', chunkIndex: 0, distance: 0.1 },
    ])
    const results = searchSimilarChunks('book-1', queryEmbedding, 5)
    expect(mockGetAllSync).toHaveBeenCalledTimes(1)
    const query = mockGetAllSync.mock.calls[0][0] as string
    expect(query).toContain('MATCH')
    expect(query).toContain('book_id')
    expect(results).toHaveLength(1)
    expect(results[0].id).toBe('c1')
  })
})

describe('isBookEmbedded', () => {
  it('returns false for empty result', () => {
    mockGetAllSync.mockReturnValue([])
    expect(isBookEmbedded('book-1')).toBe(false)
  })

  it('returns true for non-empty result', () => {
    mockGetAllSync.mockReturnValue([{ 1: 1 }])
    expect(isBookEmbedded('book-1')).toBe(true)
  })
})

describe('deleteBookChunks', () => {
  // deleteBookChunks() uses runSync() with parameterized queries (not
  // execSync + string interpolation) to prevent SQL injection. See commit
  // 756a1e2c. The bookId is passed via the second-arg params array, so we
  // assert against runSync calls and check the params separately.
  it('calls runSync with parameterized DELETE on both tables', () => {
    deleteBookChunks('book-1')
    expect(mockRunSync).toHaveBeenCalledTimes(2)
    const firstSql = mockRunSync.mock.calls[0]?.[0] as string
    const firstParams = mockRunSync.mock.calls[0]?.[1] as unknown[]
    const secondSql = mockRunSync.mock.calls[1]?.[0] as string
    const secondParams = mockRunSync.mock.calls[1]?.[1] as unknown[]
    expect(firstSql).toContain('DELETE FROM chunk_vectors')
    // bookId must travel as a parameter, NOT be interpolated into the SQL.
    expect(firstSql).not.toContain('book-1')
    expect(firstParams).toEqual(['book-1'])
    expect(secondSql).toContain('DELETE FROM chunks')
    expect(secondSql).not.toContain('book-1')
    expect(secondParams).toEqual(['book-1'])
  })
})
