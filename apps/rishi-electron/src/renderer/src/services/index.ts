import { createRagService, type RagService } from './rag'
import { createTtsService, type AuthHeader, type TtsService } from './tts'
import { createSyncService, type SyncService } from './sync'
import {
  createBookImportService,
  createScannerPort,
  type BookImportService,
  type ScannerPort
} from './book-import'
import { createConnectivityService, type ConnectivityService } from './connectivity'
export { useIsOnline } from './connectivity'
import { createVoiceChatService, type VoiceChatService } from './voice-chat'

export type { DiscoveredBook, ImportResult, PageDataInsertable, ScanProgress } from './book-import'
import { createSyncEngine } from '@rishi/shared/sync-engine'
import { embedSingleText, embedWithFallback } from '@/modules/embed-fallback'
import { hashBookFile, uploadBookFile } from '@/modules/file-sync'
import { copyBookToAppData } from '@/modules/books'
import { getAuthToken } from '@/modules/auth'
import { buildRealtimeAgent } from '@/modules/buildRealtimeAgent'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
import { getRealtimeClientSecret } from '@/lib/api'
import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import config from '@/config.json'

let _connectivity: ConnectivityService | null = null
let _connectivityOverride: ConnectivityService | null = null

export function getConnectivityService(): ConnectivityService {
  if (_connectivityOverride) return _connectivityOverride
  if (!_connectivity) {
    _connectivity = createConnectivityService({
      source: {
        get onLine() {
          return navigator.onLine
        },
        addEventListener: (type, listener) => window.addEventListener(type, listener),
        removeEventListener: (type, listener) => window.removeEventListener(type, listener)
      }
    })
    _connectivity.start()
  }
  return _connectivity
}

/** Test-only seam. Production code never sets this. */
export function setTestConnectivityService(override: ConnectivityService | null): void {
  _connectivityOverride = override
}

let _rag: RagService | null = null

export function getRagService(): RagService {
  _rag ??= createRagService({
    ipc: {
      searchVectors: window.electron.searchVectors,
      getTextFromVectorId: window.electron.getTextFromVectorId,
      searchBookText: window.electron.searchBookText,
      hasVectorsForBook: window.electron.hasVectorsForBook
    },
    embed: embedSingleText
  })
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
  _tts ??= createTtsService({
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
  return _tts
}

let _sync: SyncService | null = null

export function getSyncService(): SyncService {
  _sync ??= createSyncService({
    ipc: {
      syncGetDirtyBooks: window.electron.syncGetDirtyBooks,
      syncGetDirtyHighlights: window.electron.syncGetDirtyHighlights,
      syncGetDirtyConversations: window.electron.syncGetDirtyConversations,
      syncGetDirtyMessages: window.electron.syncGetDirtyMessages,
      syncGetLastVersion: window.electron.syncGetLastVersion,
      syncMarkBooksClean: window.electron.syncMarkBooksClean,
      syncMarkHighlightsClean: window.electron.syncMarkHighlightsClean,
      syncMarkConversationsClean: window.electron.syncMarkConversationsClean,
      syncMarkMessagesClean: window.electron.syncMarkMessagesClean,
      syncApplyBookConflict: window.electron.syncApplyBookConflict,
      syncApplyHighlightConflict: window.electron.syncApplyHighlightConflict,
      syncApplyConversationConflict: window.electron.syncApplyConversationConflict,
      syncUpsertBook: window.electron.syncUpsertBook,
      syncUpsertHighlight: window.electron.syncUpsertHighlight,
      syncUpsertConversation: window.electron.syncUpsertConversation,
      syncInsertMessage: window.electron.syncInsertMessage,
      syncUpdateLastVersion: window.electron.syncUpdateLastVersion
    },
    engineFactory: createSyncEngine,
    fetch: globalThis.fetch.bind(globalThis),
    getAuthToken,
    getDevBypassSecret: window.electron.getDevBypassSecret,
    connectivity: getConnectivityService(),
    clock: {
      now: () => Date.now(),
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: (handle) => clearTimeout(handle),
      setInterval: (fn, ms) => setInterval(fn, ms),
      clearInterval: (handle) => clearInterval(handle)
    },
    windowEvents: {
      addEventListener: (type, listener) => window.addEventListener(type, listener),
      removeEventListener: (type, listener) => window.removeEventListener(type, listener),
      dispatchEvent: (event) => window.dispatchEvent(event)
    },
    config: {
      workerUrl: 'https://api.fidexa.org',
      intervalMs: 5 * 60 * 1000,
      debounceMs: 2000,
      requestTimeoutMs: 30_000
    }
  })
  return _sync
}

let _import: BookImportService | null = null

export function getBookImportService(): BookImportService {
  if (!_import) {
    const scanner: ScannerPort = createScannerPort(
      {
        scanForBooks: async (mode) => {
          await window.electron.scanForBooks(mode)
        },
        cancelScan: () => window.electron.cancelScan()
      },
      (channel, listener) => window.electron.on(channel, listener)
    )

    _import = createBookImportService({
      formats: {
        getBookData: (path) => window.electron.getBookData(path),
        getPdfData: (path) => window.electron.getPdfData(path),
        getMobiData: (path) => window.electron.getMobiData(path),
        getAzw3Data: (path) => window.electron.getAzw3Data(path)
      },
      db: {
        saveBook: (b) => window.electron.saveBook(b),
        savePageDataMany: (rows) => window.electron.savePageDataMany(rows),
        getAllPageDataByBookId: (bookId) => window.electron.getAllPageDataByBookId(bookId),
        hasSavedEpubData: (bookId) => window.electron.hasSavedEpubData(bookId),
        saveVectors: (name, dim, vectors) => window.electron.saveVectors(name, dim, vectors)
      },
      fs: {
        copyBookToAppData,
        removeFile: (path) => window.electron.removeFile(path),
        getAppDataPath: () => window.electron.getAppDataPath()
      },
      fileSync: {
        hashBookFile,
        uploadBookFile,
        booksUpdateFileHash: (bookId, hash, r2Key) =>
          window.electron.booksUpdateFileHash(bookId, hash, r2Key)
      },
      rag: getRagService(),
      embed: embedWithFallback,
      scanner,
      config: {
        copyTimeoutMs: 2 * 60 * 1000,
        parseTimeoutMs: 60 * 1000,
        saveTimeoutMs: 30 * 1000,
        embedBatchSize: 2
      }
    })
  }
  return _import
}

let _voiceChat: VoiceChatService | null = null

export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeClientSecret },
      webrtcFactory: ({ mediaStream, audioElement }) =>
        new OpenAIRealtimeWebRTC({
          mediaStream: mediaStream as unknown as MediaStream,
          audioElement: audioElement as unknown as HTMLAudioElement
        }) as never,
      agentFactory: ({ bookId, pageText, outline, onEndConversation, rag }) =>
        buildRealtimeAgent({ bookId, pageText, outline, onEndConversation, rag }) as never,
      sessionFactory: (agent, opts) =>
        new RealtimeSession(agent as never, {
          transport: opts.transport as never,
          apiKey: opts.apiKey
        }) as never,
      media: {
        getUserMedia: (constraints) => navigator.mediaDevices.getUserMedia(constraints),
        createAudioElement: () => {
          const a = document.createElement('audio')
          a.autoplay = true
          return a
        }
      },
      effects: { playReadyChime, startThinkingSound, stopThinkingSound },
      clock: {
        now: () => Date.now(),
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: (handle) => clearTimeout(handle)
      },
      config: {
        // Auto-close after 3 minutes of no agent activity. Prevents a user
        // leaving voice chat on from racking up open-ended audio billing.
        inactivityTimeoutMs: 3 * 60 * 1000,
        connectTimeoutMs: 60 * 1000,
        keyTtlMs: 9 * 60 * 1000
      }
    })
    _voiceChat.start()
  }
  return _voiceChat
}
