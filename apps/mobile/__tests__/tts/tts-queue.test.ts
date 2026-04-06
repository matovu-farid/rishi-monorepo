jest.mock('expo-crypto', () => ({
  randomUUID: () => `uuid-${Math.random().toString(36).slice(2, 10)}`,
}))

jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(),
  writeAsStringAsync: jest.fn().mockResolvedValue(undefined),
  cacheDirectory: '/cache/',
  EncodingType: { Base64: 'base64' },
}))

jest.mock('@/lib/db', () => ({
  rawDb: {
    getAllSync: jest.fn(),
    getFirstSync: jest.fn(),
    runSync: jest.fn(),
  },
}))

jest.mock('@/lib/api', () => ({
  apiClient: jest.fn(),
}))

jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(),
}))

import { TTSQueue } from '@/lib/tts/tts-queue'
import { rawDb } from '@/lib/db'
import { apiClient } from '@/lib/api'
import { getChunks } from '@/lib/rag/chunker'
import * as FileSystem from 'expo-file-system'

const mockRawDb = rawDb as jest.Mocked<typeof rawDb>
const mockApiClient = apiClient as jest.MockedFunction<typeof apiClient>
const mockGetChunks = getChunks as jest.MockedFunction<typeof getChunks>

const testChunks = [
  { id: 'c1', text: 'Hello world.', chunk_index: 0, chunkIndex: 0, chapter: 'Ch 1' },
  { id: 'c2', text: 'Second chunk.', chunk_index: 1, chunkIndex: 1, chapter: 'Ch 1' },
]

describe('TTSQueue', () => {
  beforeEach(() => {
    jest.clearAllMocks()
  })

  describe('getBookChunksForTTS', () => {
    it('returns chunks ordered by chunk_index ASC', () => {
      mockRawDb.getAllSync.mockReturnValue(testChunks)
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      const chunks = queue.getBookChunksForTTS('book-1')
      expect(mockRawDb.getAllSync).toHaveBeenCalledWith(
        expect.stringContaining('ORDER BY chunk_index ASC'),
        ['book-1']
      )
      expect(chunks).toEqual(testChunks)
    })
  })

  describe('getChunkCount', () => {
    it('returns correct count for a book', () => {
      mockRawDb.getFirstSync.mockReturnValue({ count: 42 })
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      const count = queue.getChunkCount('book-1')
      expect(count).toBe(42)
    })

    it('returns 0 when no chunks exist', () => {
      mockRawDb.getFirstSync.mockReturnValue(null)
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      const count = queue.getChunkCount('book-1')
      expect(count).toBe(0)
    })
  })

  describe('ensureBookChunked', () => {
    it('calls getChunks and inserts into chunks table when no chunks exist', async () => {
      mockRawDb.getFirstSync.mockReturnValue({ count: 0 })
      mockGetChunks.mockResolvedValue([
        { id: 'c1', bookId: '', chunkIndex: 0, text: 'Hello.', chapter: 'Ch1', createdAt: 1000 },
      ])

      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      await queue.ensureBookChunked()

      expect(mockGetChunks).toHaveBeenCalledWith('/path/to/book.epub', 'epub')
      expect(mockRawDb.runSync).toHaveBeenCalledWith(
        expect.stringContaining('INSERT OR IGNORE'),
        expect.any(Array)
      )
    })

    it('is a no-op when chunks already exist', async () => {
      mockRawDb.getFirstSync.mockReturnValue({ count: 10 })

      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      await queue.ensureBookChunked()

      expect(mockGetChunks).not.toHaveBeenCalled()
      expect(mockRawDb.runSync).not.toHaveBeenCalled()
    })
  })

  describe('requestTTSAudio', () => {
    it('calls apiClient with correct body', async () => {
      const mockArrayBuffer = new Uint8Array([1, 2, 3]).buffer
      mockApiClient.mockResolvedValue({
        ok: true,
        arrayBuffer: () => Promise.resolve(mockArrayBuffer),
      } as unknown as Response)

      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      const uri = await queue.requestTTSAudio('Hello world.', 'c1')

      expect(mockApiClient).toHaveBeenCalledWith('/api/audio/speech', {
        method: 'POST',
        body: JSON.stringify({
          voice: 'alloy',
          input: 'Hello world.',
          response_format: 'mp3',
          speed: 1.0,
        }),
      })
      expect(uri).toContain('tts-c1.mp3')
    })
  })

  describe('queue navigation', () => {
    it('advances to next chunk after current finishes', () => {
      mockRawDb.getAllSync.mockReturnValue(testChunks)
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      queue.loadChunks()

      expect(queue.currentIndex).toBe(0)
      queue.next()
      expect(queue.currentIndex).toBe(1)
    })

    it('does not go below 0 on previous', () => {
      mockRawDb.getAllSync.mockReturnValue(testChunks)
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      queue.loadChunks()

      expect(queue.currentIndex).toBe(0)
      queue.previous()
      expect(queue.currentIndex).toBe(0)
    })

    it('does not go past last chunk on next', () => {
      mockRawDb.getAllSync.mockReturnValue(testChunks)
      const queue = new TTSQueue('book-1', '/path/to/book.epub', 'epub')
      queue.loadChunks()

      queue.next()
      queue.next() // should stay at 1 (last chunk)
      expect(queue.currentIndex).toBe(1)
    })
  })
})
