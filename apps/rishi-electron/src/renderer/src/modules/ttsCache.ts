import md5 from "md5";

/**
 * TTS Disk Cache for Electron
 *
 * Stores generated TTS audio as MP3 files in `userData/tts-cache/`,
 * using the Electron IPC bridge for all file operations.
 * Mirrors the Tauri TTSCache implementation.
 */

const TTS_CACHE_DIR = "tts-cache";
const MAX_CACHE_SIZE_MB = 500;
const CACHE_CLEANUP_THRESHOLD = 0.8; // Cleanup when 80% full

export interface CachedAudioInfo {
  filePath: string;
  exists: boolean;
}

class TTSCache {
  private cacheDir = "";
  private initPromise: Promise<void>;

  constructor() {
    this.initPromise = this.init();
  }

  private async init(): Promise<void> {
    const appData = await window.electron.getAppDataPath();
    this.cacheDir = `${appData}/${TTS_CACHE_DIR}`;
    await this.ensureCacheDirExists();
  }

  private ready(): Promise<void> {
    return this.initPromise;
  }

  private async ensureCacheDirExists(): Promise<void> {
    try {
      await window.electron.mkdir(this.cacheDir);
    } catch (error) {
      console.error("Failed to create TTS cache directory:", error);
      throw new Error(`Failed to create TTS cache directory: ${error}`);
    }
  }

  private async getBookCacheDir(bookId: string): Promise<string> {
    await this.ready();
    return `${this.cacheDir}/${bookId}`;
  }

  private async getAudioFilePath(
    bookId: string,
    cfiRange: string,
  ): Promise<string> {
    try {
      const bookCacheDir = await this.getBookCacheDir(bookId);
      const dirExists = await window.electron.exists(bookCacheDir);

      if (!dirExists) {
        await window.electron.mkdir(bookCacheDir);
      }

      const hashedCfi = md5(cfiRange);
      return `${bookCacheDir}/${hashedCfi}.mp3`;
    } catch (error) {
      console.error(">>> Cache: Error getting audio file path", {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + "...",
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error),
      });
      throw error;
    }
  }

  /**
   * Check if audio is cached for a given CFI range.
   * Returns the file path and whether it exists on disk.
   */
  async getCachedAudio(
    bookId: string,
    cfiRange: string,
    textHash?: string,
  ): Promise<CachedAudioInfo> {
    try {
      // Try CFI-based key first
      const filePath = await this.getAudioFilePath(bookId, cfiRange);
      const exists = await window.electron.exists(filePath);

      if (exists) {
        return { filePath, exists: true };
      }

      // Fall back to text-hash key if provided
      if (textHash) {
        const textHashKey = `texthash:${md5(textHash)}`;
        const textHashPath = await this.getAudioFilePath(bookId, textHashKey);
        const textHashExists = await window.electron.exists(textHashPath);
        if (textHashExists) {
          return { filePath: textHashPath, exists: true };
        }
      }

      return { filePath, exists: false };
    } catch (error) {
      console.error(">>> Cache: Error checking cached audio", {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + "...",
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error),
      });
      throw error;
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
    textHash?: string,
  ): Promise<string> {
    try {
      const filePath = await this.getAudioFilePath(bookId, cfiRange);

      // Check cache size before saving
      await this.checkAndCleanupCache();

      // Convert Blob to Uint8Array for IPC
      const arrayBuffer = await audioBlob.arrayBuffer();
      const uint8Array = new Uint8Array(arrayBuffer);

      await window.electron.writeFile(filePath, uint8Array);

      // Verify file was created
      const exists = await window.electron.exists(filePath);
      if (!exists) {
        throw new Error("File was not created successfully");
      }

      // If text is provided, save a copy under the text-hash key
      if (textHash && !cfiRange.startsWith("texthash:")) {
        const textHashKey = `texthash:${md5(textHash)}`;
        try {
          const textHashPath = await this.getAudioFilePath(bookId, textHashKey);
          const textHashExists = await window.electron.exists(textHashPath);
          if (!textHashExists) {
            await window.electron.copyFile(filePath, textHashPath);
          }
        } catch {
          // Non-critical -- text-hash copy failed, CFI-based lookup still works
        }
      }

      return filePath;
    } catch (error) {
      const errorDetails = {
        bookId,
        cfiRange: cfiRange.substring(0, 50) + "...",
        blobSize: audioBlob.size,
        cacheDir: this.cacheDir,
        error:
          error instanceof Error
            ? { name: error.name, message: error.message, stack: error.stack }
            : String(error),
      };

      console.error(">>> Cache: Failed to save cached audio", errorDetails);
      throw new Error(
        `Failed to save cached audio: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * Read cached audio from disk and return a blob URL.
   */
  async getCachedAudioUrl(
    bookId: string,
    cfiRange: string,
    textHash?: string,
  ): Promise<string | null> {
    try {
      const info = await this.getCachedAudio(bookId, cfiRange, textHash);
      if (!info.exists) return null;

      const arrayBuffer = await window.electron.readFile(info.filePath);
      const blob = new Blob([arrayBuffer], { type: "audio/mpeg" });
      return URL.createObjectURL(blob);
    } catch (error) {
      console.error(">>> Cache: Error reading cached audio URL", error);
      return null;
    }
  }

  /**
   * Clear all cached audio for a book.
   */
  async clearBookCache(bookId: string): Promise<void> {
    try {
      const bookCacheDir = await this.getBookCacheDir(bookId);
      const exists = await window.electron.exists(bookCacheDir);
      if (exists) {
        // Read the directory and remove each file
        const files = await window.electron.readDir(bookCacheDir);
        for (const file of files) {
          try {
            await window.electron.removeFile(`${bookCacheDir}/${file}`);
          } catch {
            // Ignore individual file deletion errors
          }
        }
        // Try to remove the now-empty directory
        try {
          await window.electron.removeFile(bookCacheDir);
        } catch {
          // Directory may not be empty or other error - ignore
        }
      }
    } catch (error) {
      console.warn(`Could not clear book cache: ${error}`);
    }
  }

  /**
   * Get total cache size across all books (in bytes).
   */
  async getTotalCacheSize(): Promise<number> {
    try {
      await this.ready();
      return await window.electron.getDirSize(this.cacheDir);
    } catch {
      return 0;
    }
  }

  /**
   * Check cache size and trigger cleanup if necessary.
   */
  private async checkAndCleanupCache(): Promise<void> {
    try {
      const totalSizeBytes = await this.getTotalCacheSize();
      const totalSizeMB = totalSizeBytes / (1024 * 1024);

      if (totalSizeMB > MAX_CACHE_SIZE_MB * CACHE_CLEANUP_THRESHOLD) {
        await this.cleanupOldestFiles();
      }
    } catch (error) {
      console.error("Failed to check cache size:", error);
    }
  }

  /**
   * Remove oldest files until cache is under the cleanup threshold.
   */
  private async cleanupOldestFiles(): Promise<void> {
    try {
      await this.ready();
      const fileStats = await window.electron.getCacheFileStats(this.cacheDir);

      // Sort by modification time (oldest first)
      fileStats.sort((a, b) => a.mtimeMs - b.mtimeMs);

      const targetSizeBytes =
        MAX_CACHE_SIZE_MB * CACHE_CLEANUP_THRESHOLD * 1024 * 1024;
      let currentSize = await this.getTotalCacheSize();

      for (const fileStat of fileStats) {
        if (currentSize <= targetSizeBytes) break;

        try {
          await window.electron.removeFile(fileStat.path);
          currentSize -= fileStat.size;
        } catch (error) {
          console.warn(
            `Failed to remove cache file ${fileStat.path}:`,
            error,
          );
        }
      }
    } catch (error) {
      console.error("Failed to cleanup cache files:", error);
    }
  }
}

export const ttsCache = new TTSCache();
