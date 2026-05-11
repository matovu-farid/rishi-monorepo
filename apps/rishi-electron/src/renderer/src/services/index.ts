import { createRagService, type RagService } from './rag'
import { createTtsService, type AuthHeader, type TtsService } from './tts'
import { embedSingleText } from '@/modules/embed-fallback'
import { getAuthToken } from '@/modules/auth'
import config from '@/config.json'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook
      },
      embed: embedSingleText
    })
  }
  return _rag
}

let _tts: TtsService | null = null

/**
 * Resolves the auth header for the TTS transport.
 *
 * - If the main process has a Better Auth token, send it as `Bearer`.
 * - Otherwise, fall back to the dev-bypass secret (only present in dev builds
 *   when configured). If neither is available, throw — the service will
 *   surface this via its onError emitter.
 */
async function resolveTtsAuth(): Promise<AuthHeader> {
  const token = await getAuthToken()
  if (token) return { kind: 'bearer', token }
  const devBypassSecret = await window.electron.getDevBypassSecret()
  if (devBypassSecret) return { kind: 'dev-bypass', secret: devBypassSecret }
  throw new Error('Not authenticated -- sign in to use text-to-speech')
}

export function getTtsService(): TtsService {
  if (!_tts) {
    _tts = createTtsService({
      ipc: {
        mkdir: window.electron.mkdir,
        exists: window.electron.exists,
        writeFile: window.electron.writeFile,
        readFile: window.electron.readFile,
        copyFile: window.electron.copyFile,
        removeFile: window.electron.removeFile,
        getDirSize: window.electron.getDirSize,
        getCacheFileStats: window.electron.getCacheFileStats,
        getAppDataPath: window.electron.getAppDataPath
      },
      fetch: globalThis.fetch.bind(globalThis),
      getAuthToken: resolveTtsAuth,
      config: {
        audioWorkerUrl: config.production.audio_worker_url,
        cacheMaxBytes: 500 * 1024 * 1024,
        maxConcurrent: 8
      }
    })
  }
  return _tts
}
