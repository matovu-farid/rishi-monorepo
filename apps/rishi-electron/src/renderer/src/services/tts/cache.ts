import md5 from 'md5'
import type { TtsIpcChannels } from './types'

const TTS_CACHE_DIR = 'tts-cache'

export interface CacheDeps {
  ipc: TtsIpcChannels
  cacheMaxBytes: number
}

export interface Cache {
  audioPath(bookId: string, cfiRange: string): Promise<string>
  getAudio(bookId: string, cfiRange: string, textHash?: string): Promise<ArrayBuffer | null>
  saveAudio(
    bookId: string,
    cfiRange: string,
    bytes: Uint8Array,
    textHash?: string
  ): Promise<string>
  clearBook(bookId: string): Promise<void>
  evictIfNeeded(): Promise<void>
}

export function createCache(deps: CacheDeps): Cache {
  const { ipc } = deps
  let rootDir = ''
  let initPromise: Promise<void> | null = null
  const knownBookDirs = new Set<string>()

  async function init(): Promise<void> {
    if (!initPromise) {
      initPromise = (async () => {
        const appData = await ipc.getAppDataPath()
        rootDir = `${appData}/${TTS_CACHE_DIR}`
        await ipc.mkdir(rootDir)
      })()
    }
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

  async function audioPath(bookId: string, cfiRange: string): Promise<string> {
    const dir = await bookDir(bookId)
    return `${dir}/${md5(cfiRange)}.mp3`
  }

  return {
    audioPath,
    async getAudio(bookId, cfiRange, textHash) {
      const cfiPath = await audioPath(bookId, cfiRange)
      if (await ipc.exists(cfiPath)) {
        return ipc.readFile(cfiPath)
      }
      if (textHash) {
        const mirror = await audioPath(bookId, `texthash:${md5(textHash)}`)
        if (await ipc.exists(mirror)) {
          return ipc.readFile(mirror)
        }
      }
      return null
    },
    async saveAudio(bookId, cfiRange, bytes, textHash) {
      if (bytes.byteLength === 0) {
        throw new Error('Audio blob is zero bytes, skipping cache write')
      }
      const path = await audioPath(bookId, cfiRange)
      await ipc.writeFile(path, bytes)

      if (textHash && !cfiRange.startsWith('texthash:')) {
        try {
          const mirror = await audioPath(bookId, `texthash:${md5(textHash)}`)
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
      throw new Error('not implemented')
    }
  }
}
