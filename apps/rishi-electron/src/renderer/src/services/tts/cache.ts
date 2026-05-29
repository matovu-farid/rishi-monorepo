import md5 from 'md5'
import type { TtsIpcChannels } from './types'

const TTS_CACHE_DIR = 'tts-cache'

export interface CacheDeps {
  ipc: TtsIpcChannels
  cacheMaxBytes: number
}

export interface Cache {
  audioPath(bookId: string, cfiRange: string, text?: string): Promise<string>
  getAudio(bookId: string, cfiRange: string, text?: string): Promise<ArrayBuffer | null>
  saveAudio(bookId: string, cfiRange: string, bytes: Uint8Array, text?: string): Promise<string>
  clearBook(bookId: string): Promise<void>
  evictIfNeeded(): Promise<void>
}

export function createCache(deps: CacheDeps): Cache {
  const { ipc } = deps
  let rootDir = ''
  let initPromise: Promise<void> | null = null
  const knownBookDirs = new Set<string>()

  async function init(): Promise<void> {
    initPromise ??= (async () => {
      const appData = await ipc.getAppDataPath()
      rootDir = `${appData}/${TTS_CACHE_DIR}`
      await ipc.mkdir(rootDir)
    })()
    return initPromise
  }

  async function bookDir(bookId: string): Promise<string> {
    await init()
    const dir = `${rootDir}/${bookId}`
    if (!knownBookDirs.has(dir)) {
      const exists = await ipc.exists(dir)
      if (!exists) await ipc.mkdir(dir)
      knownBookDirs.add(dir)
    }
    return dir
  }

  async function audioPath(bookId: string, cfiRange: string, text?: string): Promise<string> {
    const dir = await bookDir(bookId)
    const suffix = text ? `-${md5(text)}` : ''
    return `${dir}/${md5(cfiRange)}${suffix}.mp3`
  }

  return {
    audioPath,
    async getAudio(bookId, cfiRange, text) {
      const cfiPath = await audioPath(bookId, cfiRange, text)
      if (await ipc.exists(cfiPath)) {
        return ipc.readFile(cfiPath)
      }
      if (text) {
        const mirror = await audioPath(bookId, `texthash:${md5(text)}`, text)
        if (await ipc.exists(mirror)) {
          return ipc.readFile(mirror)
        }
      }
      return null
    },
    async saveAudio(bookId, cfiRange, bytes, text) {
      if (bytes.byteLength === 0) {
        throw new Error('Audio blob is zero bytes, skipping cache write')
      }
      const path = await audioPath(bookId, cfiRange, text)
      await ipc.writeFile(path, bytes)

      if (text && !cfiRange.startsWith('texthash:')) {
        try {
          const mirror = await audioPath(bookId, `texthash:${md5(text)}`, text)
          const mirrorExists = await ipc.exists(mirror)
          if (!mirrorExists) await ipc.copyFile(path, mirror)
        } catch {
          // Non-critical — CFI-based lookup still works
        }
      }
      return path
    },
    async clearBook(bookId) {
      await init()
      const dir = `${rootDir}/${bookId}`
      knownBookDirs.delete(dir)
      if (await ipc.exists(dir)) {
        await ipc.removeFile(dir)
      }
    },
    async evictIfNeeded() {
      await init()
      const total = await ipc.getDirSize(rootDir)
      const threshold = deps.cacheMaxBytes * 0.8
      if (total <= threshold) return

      const stats = await ipc.getCacheFileStats(rootDir)
      stats.sort((a, b) => a.mtimeMs - b.mtimeMs) // oldest first
      let current = total
      for (const file of stats) {
        if (current <= threshold) break
        try {
          // eslint-disable-next-line no-await-in-loop -- LRU eviction: each iteration's `current` decision depends on the prior removal completing so we stop as soon as we're under the threshold.
          await ipc.removeFile(file.path)
          current -= file.size
        } catch {
          // best-effort
        }
      }
    }
  }
}
