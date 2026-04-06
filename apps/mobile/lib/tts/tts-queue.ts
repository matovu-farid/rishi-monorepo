import { rawDb } from '@/lib/db'
import { apiClient } from '@/lib/api'
import { getChunks } from '@/lib/rag/chunker'
import * as FileSystem from 'expo-file-system'

interface ChunkRow {
  id: string
  text: string
  chunkIndex: number
  chapter: string | null
}

/**
 * TTS chunk queue manager.
 * Fetches text chunks from SQLite, requests audio from the Worker TTS endpoint,
 * writes mp3 files to cache, and manages sequential playback position.
 */
export class TTSQueue {
  readonly bookId: string
  readonly filePath: string
  readonly format: 'epub' | 'pdf'

  private _chunks: ChunkRow[] = []
  private _currentIndex: number = 0
  private _audioCache = new Map<string, string>() // chunkId -> file URI

  constructor(bookId: string, filePath: string, format: 'epub' | 'pdf') {
    this.bookId = bookId
    this.filePath = filePath
    this.format = format
  }

  /** Current position in the chunk list */
  get currentIndex(): number {
    return this._currentIndex
  }

  /** All loaded chunks */
  get chunks(): ChunkRow[] {
    return this._chunks
  }

  /** Total number of loaded chunks */
  getTotalChunks(): number {
    return this._chunks.length
  }

  /** Current chunk at the playback position */
  getCurrentChunk(): ChunkRow | undefined {
    return this._chunks[this._currentIndex]
  }

  /** Advance to the next chunk (clamped to last) */
  next(): boolean {
    if (this._currentIndex < this._chunks.length - 1) {
      this._currentIndex++
      return true
    }
    return false
  }

  /** Go back to the previous chunk (clamped to 0) */
  previous(): boolean {
    if (this._currentIndex > 0) {
      this._currentIndex--
      return true
    }
    return false
  }

  /** Reset position to start */
  reset(): void {
    this._currentIndex = 0
  }

  /**
   * Fetch all chunks for a book ordered by chunk_index ASC.
   */
  getBookChunksForTTS(bookId: string): ChunkRow[] {
    return rawDb.getAllSync(
      'SELECT id, text, chunk_index as chunkIndex, chapter FROM chunks WHERE book_id = ? ORDER BY chunk_index ASC',
      [bookId]
    ) as ChunkRow[]
  }

  /**
   * Get the count of chunks for a book.
   */
  getChunkCount(bookId: string): number {
    const row = rawDb.getFirstSync(
      'SELECT COUNT(*) as count FROM chunks WHERE book_id = ?',
      [bookId]
    ) as { count: number } | null
    return row?.count ?? 0
  }

  /**
   * Ensure a book has been chunked. If no chunks exist,
   * extracts text and inserts chunks into the chunks table.
   */
  async ensureBookChunked(): Promise<void> {
    const count = this.getChunkCount(this.bookId)
    if (count > 0) return

    const textChunks = await getChunks(this.filePath, this.format)
    for (const chunk of textChunks) {
      rawDb.runSync(
        'INSERT OR IGNORE INTO chunks (id, book_id, chunk_index, text, chapter, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [chunk.id, this.bookId, chunk.chunkIndex, chunk.text, chunk.chapter, chunk.createdAt]
      )
    }
  }

  /**
   * Load chunks from the database into memory.
   */
  loadChunks(): void {
    this._chunks = this.getBookChunksForTTS(this.bookId)
  }

  /**
   * Request TTS audio for a text chunk from the Worker API.
   * Returns the local file URI of the cached mp3.
   */
  async requestTTSAudio(text: string, chunkId: string): Promise<string> {
    // Check cache first
    const cached = this._audioCache.get(chunkId)
    if (cached) return cached

    const response = await apiClient('/api/audio/speech', {
      method: 'POST',
      body: JSON.stringify({
        voice: 'alloy',
        input: text,
        response_format: 'mp3',
        speed: 1.0,
      }),
    })

    const arrayBuffer = await response.arrayBuffer()
    const bytes = new Uint8Array(arrayBuffer)

    // Convert to base64 for writing
    let binary = ''
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i])
    }
    const base64 = btoa(binary)

    const uri = `${FileSystem.cacheDirectory}tts-${chunkId}.mp3`
    await FileSystem.writeAsStringAsync(uri, base64, {
      encoding: FileSystem.EncodingType.Base64,
    })

    this._audioCache.set(chunkId, uri)
    return uri
  }

  /**
   * Prefetch audio for the next N chunks in background.
   */
  async prefetchNext(count: number = 2): Promise<void> {
    const start = this._currentIndex + 1
    const end = Math.min(start + count, this._chunks.length)

    const promises: Promise<void>[] = []
    for (let i = start; i < end; i++) {
      const chunk = this._chunks[i]
      if (chunk && !this._audioCache.has(chunk.id)) {
        promises.push(
          this.requestTTSAudio(chunk.text, chunk.id).then(() => {})
        )
      }
    }
    await Promise.allSettled(promises)
  }

  /**
   * Delete a cached audio file.
   */
  async deleteCachedAudio(chunkId: string): Promise<void> {
    const uri = this._audioCache.get(chunkId)
    if (uri) {
      try {
        await FileSystem.deleteAsync(uri, { idempotent: true })
      } catch {
        // Ignore cleanup errors
      }
      this._audioCache.delete(chunkId)
    }
  }

  /**
   * Clean up all cached audio files.
   */
  async cleanupAll(): Promise<void> {
    const promises = Array.from(this._audioCache.keys()).map((id) =>
      this.deleteCachedAudio(id)
    )
    await Promise.allSettled(promises)
  }
}
