const mockExecSync = jest.fn()
const mockRunSync = jest.fn(() => ({ lastInsertRowId: 42 }))
const mockGetAllSync = jest.fn(() => [])

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
  it('calls execSync for DELETE on both tables', () => {
    deleteBookChunks('book-1')
    expect(mockExecSync).toHaveBeenCalledTimes(2)
    const firstCall = mockExecSync.mock.calls[0][0] as string
    const secondCall = mockExecSync.mock.calls[1][0] as string
    expect(firstCall).toContain('DELETE FROM chunk_vectors')
    expect(firstCall).toContain('book-1')
    expect(secondCall).toContain('DELETE FROM chunks')
    expect(secondCall).toContain('book-1')
  })
})
