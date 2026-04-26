import md5 from 'md5'

/**
 * TTS Disk Cache for Electron
 *
 * Stores generated TTS audio as MP3 files in `userData/tts-cache/`,
 * using the Electron IPC bridge for all file operations.
 * Mirrors the Tauri TTSCache implementation.
 */

const TTS_CACHE_DIR = 'tts-cache'
const MAX_CACHE_SIZE_MB = 500
const CACHE_CLEANUP_THRESHOLD = 0.8 // Cleanup when 80% full

export interface CachedAudioInfo {
  filePath: string
  exists: boolean
}

class TTSCache {
  private cacheDir = ''
  private initPromise: Promise<void>
  /** Track book directories we've already created to skip redundant IPC exists+mkdir calls */
  private knownBookDirs = new Set<string>()
  /** Throttle cache cleanup -- only check once per interval */
  private lastCleanupCheck = 0
  private static readonly CLEANUP_INTERVAL_MS = 60_000 // 1 minute between checks

  constructor() {
    this.initPromise = this.init()
  }

  private async init(): Promise<void> {
    const appData = await window.electron.getAppDataPath()
    this.cacheDir = `${appData}/${TTS_CACHE_DIR}`
    await this.ensureCacheDirExists()
  }

  private ready(): Promise<void> {
    return this.initPromise
  }

  private async ensureCacheDirExists(): Promise<void> {
    try {
      await window.electron.mkdir(this.cacheDir)
    } catch (error) {
      console.error('Failed to create TTS cache directory:', error)
      throw new Error(`Failed to create TTS cache directory: ${error}`)
    }
  }

  private async getBookCacheDir(bookId: string): Promise<string> {
    await this.ready()
    return `${this.cacheDir}/${bookId}`
  }

  private async getAudioFilePath(bookId: string, cfiRange: string): Promise<string> {
    try {
      const bookCacheDir = await this.getBookCacheDir(bookId)

      // Only do the IPC exists+mkdir roundtrip once per book directory
      if (!this.knownBookDirs.has(bookCacheDir)) {
        const dirExists = await window.electron.exists(bookCacheDir)
        if (!dirExists) {
          await window.electron.mkdir(bookCacheDir)
        }
        this.knownBookDirs.add(bookCacheDir)
      }

      const hashedCfi = md5(cfiRange)
      return `${bookCacheDir}/${hashedCfi}.mp3`
    } catch (error) {
      console.error('>>> Cache: Error getting audio file path', {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + '...',
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error)
      })
      throw error
    }
  }

  /**
   * Check if audio is cached for a given CFI range.
   * Returns the file path and whether it exists on disk.
   */
  async getCachedAudio(
    bookId: string,
    cfiRange: string,
    textHash?: string
  ): Promise<CachedAudioInfo> {
    try {
      // Try CFI-based key first
      const filePath = await this.getAudioFilePath(bookId, cfiRange)
      const exists = await window.electron.exists(filePath)

      if (exists) {
        return { filePath, exists: true }
      }

      // Fall back to text-hash key if provided
      if (textHash) {
        const textHashKey = `texthash:${md5(textHash)}`
        const textHashPath = await this.getAudioFilePath(bookId, textHashKey)
        const textHashExists = await window.electron.exists(textHashPath)
        if (textHashExists) {
          return { filePath: textHashPath, exists: true }
        }
      }

      return { filePath, exists: false }
    } catch (error) {
      console.error('>>> Cache: Error checking cached audio', {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + '...',
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error)
      })
      throw error
    }
  }

  /**
   * Save generated audio to disk cache.
   * When `text` is provided, also saves under a text-hash key so lookups by
   * either CFI or text content both hit the cache.
   */
  async saveCachedAudio(
    bookId: string,
    cfiRange: string,
    audioBlob: Blob,
    textHash?: string
  ): Promise<string> {
    try {
      const filePath = await this.getAudioFilePath(bookId, cfiRange)

      // Check cache size before saving
      await this.checkAndCleanupCache()

      // Convert Blob to Uint8Array for IPC
      const arrayBuffer = await audioBlob.arrayBuffer()
      const uint8Array = new Uint8Array(arrayBuffer)

      // Validate input before writing -- avoids a wasteful write + read-back cycle
      if (uint8Array.byteLength === 0) {
        throw new Error('Audio blob is zero bytes, skipping cache write')
      }

      await window.electron.writeFile(filePath, uint8Array)

      // If text is provided, save a copy under the text-hash key
      if (textHash && !cfiRange.startsWith('texthash:')) {
        const textHashKey = `texthash:${md5(textHash)}`
        try {
          const textHashPath = await this.getAudioFilePath(bookId, textHashKey)
          const textHashExists = await window.electron.exists(textHashPath)
          if (!textHashExists) {
            await window.electron.copyFile(filePath, textHashPath)
          }
        } catch {
          // Non-critical -- text-hash copy failed, CFI-based lookup still works
        }
      }

      return filePath
    } catch (error) {
      const errorDetails = {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + '...',
        blobSize: audioBlob.size,
        cacheDir: this.cacheDir,
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error)
      }

      console.error('>>> Cache: Failed to save cached audio', errorDetails)
      throw new Error(
        `Failed to save cached audio: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }

  /**
   * Read cached audio from disk and return the raw ArrayBuffer.
   * The caller is responsible for creating (and revoking) any blob URLs.
   */
  async getCachedAudioData(
    bookId: string,
    cfiRange: string,
    textHash?: string
  ): Promise<ArrayBuffer | null> {
    try {
      const info = await this.getCachedAudio(bookId, cfiRange, textHash)
      if (!info.exists) return null

      return await window.electron.readFile(info.filePath)
    } catch (error) {
      console.error('>>> Cache: Error reading cached audio data', error)
      return null
    }
  }

  /**
   * Clear all cached audio for a book.
   */
  async clearBookCache(bookId: string): Promise<void> {
    try {
      const bookCacheDir = await this.getBookCacheDir(bookId)
      // Remove from memoized set so the next write re-creates the directory
      this.knownBookDirs.delete(bookCacheDir)
      const exists = await window.electron.exists(bookCacheDir)
      if (exists) {
        // removeFile uses fs.rm with recursive: true, so one call handles everything
        await window.electron.removeFile(bookCacheDir)
      }
    } catch (error) {
      console.warn(`Could not clear book cache: ${error}`)
    }
  }

  /**
   * Get cache size for a specific book (in bytes).
   */
  async getBookCacheSize(bookId: string): Promise<number> {
    try {
      const bookCacheDir = await this.getBookCacheDir(bookId)
      const exists = await window.electron.exists(bookCacheDir)
      if (!exists) return 0
      return await window.electron.getDirSize(bookCacheDir)
    } catch {
      return 0
    }
  }

  /**
   * Get total cache size across all books (in bytes).
   */
  async getTotalCacheSize(): Promise<number> {
    try {
      await this.ready()
      return await window.electron.getDirSize(this.cacheDir)
    } catch {
      return 0
    }
  }

  /**
   * Check cache size and trigger cleanup if necessary.
   */
  private async checkAndCleanupCache(): Promise<void> {
    // Throttle: skip if we checked recently (avoids walking the entire cache dir on every save)
    const now = Date.now()
    if (now - this.lastCleanupCheck < TTSCache.CLEANUP_INTERVAL_MS) return
    this.lastCleanupCheck = now

    try {
      const totalSizeBytes = await this.getTotalCacheSize()
      const totalSizeMB = totalSizeBytes / (1024 * 1024)

      if (totalSizeMB > MAX_CACHE_SIZE_MB * CACHE_CLEANUP_THRESHOLD) {
        await this.cleanupOldestFiles()
      }
    } catch (error) {
      console.error('Failed to check cache size:', error)
    }
  }

  /**
   * Remove oldest files until cache is under the cleanup threshold.
   */
  private async cleanupOldestFiles(): Promise<void> {
    try {
      await this.ready()
      const fileStats = await window.electron.getCacheFileStats(this.cacheDir)

      // Sort by modification time (oldest first)
      fileStats.sort((a, b) => a.mtimeMs - b.mtimeMs)

      const targetSizeBytes = MAX_CACHE_SIZE_MB * CACHE_CLEANUP_THRESHOLD * 1024 * 1024
      let currentSize = await this.getTotalCacheSize()

      for (const fileStat of fileStats) {
        if (currentSize <= targetSizeBytes) break

        try {
          await window.electron.removeFile(fileStat.path)
          currentSize -= fileStat.size
        } catch (error) {
          console.warn(`Failed to remove cache file ${fileStat.path}:`, error)
        }
      }
    } catch (error) {
      console.error('Failed to cleanup cache files:', error)
    }
  }
}

export const ttsCache = new TTSCache()
