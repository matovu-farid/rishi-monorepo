jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(),
}))

jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(),
  isEmbeddingReady: jest.fn(),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn(),
  isBookEmbedded: jest.fn(),
  deleteBookChunks: jest.fn(),
}))

jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: jest.fn(),
}))

import { embedBook, reembedBook } from '@/lib/rag/pipeline'
import { getChunks } from '@/lib/rag/chunker'
import { embedBatch, isEmbeddingReady } from '@/lib/rag/embedder'
import { insertChunkWithVector, isBookEmbedded, deleteBookChunks } from '@/lib/rag/vector-store'
import { embedTextsOnServer } from '@/lib/rag/server-fallback'

const mockGetChunks = getChunks as jest.MockedFunction<typeof getChunks>
const mockEmbedBatch = embedBatch as jest.MockedFunction<typeof embedBatch>
const mockIsBookEmbedded = isBookEmbedded as jest.MockedFunction<typeof isBookEmbedded>
const mockInsertChunkWithVector = insertChunkWithVector as jest.MockedFunction<typeof insertChunkWithVector>
const mockDeleteBookChunks = deleteBookChunks as jest.MockedFunction<typeof deleteBookChunks>
const mockIsEmbeddingReady = isEmbeddingReady as jest.MockedFunction<typeof isEmbeddingReady>
const mockEmbedTextsOnServer = embedTextsOnServer as jest.MockedFunction<typeof embedTextsOnServer>

function makeChunks(count: number) {
  return Array.from({ length: count }, (_, i) => ({
    id: `chunk-${i}`,
    bookId: 'book-1',
    chunkIndex: i,
    text: `Chunk text ${i}`,
    chapter: i < 5 ? 'Chapter 1' : 'Chapter 2',
    createdAt: Date.now(),
  }))
}

describe('embedBook', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    mockIsEmbeddingReady.mockReturnValue(true)
  })

  it('returns early if book is already embedded', async () => {
    mockIsBookEmbedded.mockReturnValue(true)
    const onProgress = jest.fn()

    await embedBook('book-1', '/path/to/book.epub', 'epub', onProgress)

    expect(mockIsBookEmbedded).toHaveBeenCalledWith('book-1')
    expect(mockGetChunks).not.toHaveBeenCalled()
    expect(onProgress).toHaveBeenCalledWith(1)
  })

  it('calls getChunks with filePath and format', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    mockGetChunks.mockResolvedValue([])

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockGetChunks).toHaveBeenCalledWith('/path/to/book.epub', 'epub')
  })

  it('processes chunks in batches of 10', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(25)
    mockGetChunks.mockResolvedValue(chunks)
    mockEmbedBatch.mockResolvedValue(new Array(10).fill(new Array(384).fill(0.1)))

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    // 25 chunks = 3 batches (10, 10, 5)
    expect(mockEmbedBatch).toHaveBeenCalledTimes(3)
    expect(mockEmbedBatch.mock.calls[0][0]).toHaveLength(10)
    expect(mockEmbedBatch.mock.calls[1][0]).toHaveLength(10)
    expect(mockEmbedBatch.mock.calls[2][0]).toHaveLength(5)
  })

  it('calls insertChunkWithVector for each chunk', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(3)
    mockGetChunks.mockResolvedValue(chunks)
    const embedding = new Array(384).fill(0.1)
    mockEmbedBatch.mockResolvedValue([embedding, embedding, embedding])

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockInsertChunkWithVector).toHaveBeenCalledTimes(3)
    expect(mockInsertChunkWithVector).toHaveBeenCalledWith(
      'chunk-0', 'book-1', 0, 'Chunk text 0', 'Chapter 1', embedding
    )
  })

  it('calls onProgress with increasing values up to 1', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(25)
    mockGetChunks.mockResolvedValue(chunks)
    mockEmbedBatch.mockResolvedValue(new Array(10).fill(new Array(384).fill(0.1)))

    const onProgress = jest.fn()
    await embedBook('book-1', '/path/to/book.epub', 'epub', onProgress)

    // Should be called for each batch + final
    expect(onProgress).toHaveBeenCalled()
    const calls = onProgress.mock.calls.map((c: any[]) => c[0])
    // Progress should be increasing
    for (let i = 1; i < calls.length; i++) {
      expect(calls[i]).toBeGreaterThanOrEqual(calls[i - 1])
    }
    // Last call should be 1
    expect(calls[calls.length - 1]).toBe(1)
  })

  it('handles empty chunks gracefully', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    mockGetChunks.mockResolvedValue([])
    const onProgress = jest.fn()

    await embedBook('book-1', '/path/to/book.epub', 'epub', onProgress)

    expect(mockEmbedBatch).not.toHaveBeenCalled()
    expect(onProgress).toHaveBeenCalledWith(1)
  })
})

describe('reembedBook', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    mockIsEmbeddingReady.mockReturnValue(true)
  })

  it('deletes existing chunks then re-embeds', async () => {
    mockIsBookEmbedded.mockReturnValue(false)
    mockGetChunks.mockResolvedValue(makeChunks(2))
    mockEmbedBatch.mockResolvedValue([new Array(384).fill(0), new Array(384).fill(0)])

    await reembedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockDeleteBookChunks).toHaveBeenCalledWith('book-1')
    expect(mockGetChunks).toHaveBeenCalled()
  })
})

describe('embedBatchWithFallback (via embedBook)', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  it('uses server fallback when isEmbeddingReady returns false', async () => {
    mockIsEmbeddingReady.mockReturnValue(false)
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(3)
    mockGetChunks.mockResolvedValue(chunks)
    const embedding = new Array(384).fill(0.5)
    mockEmbedTextsOnServer.mockResolvedValue([embedding, embedding, embedding])

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockEmbedTextsOnServer).toHaveBeenCalled()
    expect(mockEmbedBatch).not.toHaveBeenCalled()
    expect(mockInsertChunkWithVector).toHaveBeenCalledTimes(3)
  })

  it('uses server fallback when embedBatch throws', async () => {
    mockIsEmbeddingReady.mockReturnValue(true)
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(3)
    mockGetChunks.mockResolvedValue(chunks)
    mockEmbedBatch.mockRejectedValue(new Error('Model inference failed'))
    const embedding = new Array(384).fill(0.5)
    mockEmbedTextsOnServer.mockResolvedValue([embedding, embedding, embedding])

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockEmbedBatch).toHaveBeenCalled()
    expect(mockEmbedTextsOnServer).toHaveBeenCalled()
    expect(mockInsertChunkWithVector).toHaveBeenCalledTimes(3)
  })

  it('uses on-device when isEmbeddingReady returns true and embedBatch succeeds', async () => {
    mockIsEmbeddingReady.mockReturnValue(true)
    mockIsBookEmbedded.mockReturnValue(false)
    const chunks = makeChunks(3)
    mockGetChunks.mockResolvedValue(chunks)
    const embedding = new Array(384).fill(0.1)
    mockEmbedBatch.mockResolvedValue([embedding, embedding, embedding])

    await embedBook('book-1', '/path/to/book.epub', 'epub')

    expect(mockEmbedBatch).toHaveBeenCalled()
    expect(mockEmbedTextsOnServer).not.toHaveBeenCalled()
    expect(mockInsertChunkWithVector).toHaveBeenCalledTimes(3)
  })
})
