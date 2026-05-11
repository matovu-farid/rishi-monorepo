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
    async getAudio() {
      throw new Error('not implemented')
    },
    async saveAudio() {
      throw new Error('not implemented')
    },
    async clearBook() {
      throw new Error('not implemented')
    },
    async evictIfNeeded() {
      throw new Error('not implemented')
    }
  }
}
