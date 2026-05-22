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
import {
  createVoiceChatService,
  createLocalVad,
  type LocalVadConfig,
  type MediaRecorderLike,
  type ServerVadConfig,
  type VoiceChatService
} from './voice-chat'

export type { DiscoveredBook, ImportResult, ImportSuccess, PageDataInsertable, ScanProgress } from './book-import'
import { createSyncEngine } from '@rishi/shared/sync-engine'
import { embedSingleText, embedWithFallback } from '@/modules/embed-fallback'
import { hashBookFile, uploadBookFile, getFileSize } from '@/modules/file-sync'
import { copyBookToAppData } from '@/modules/books'
import { getAuthToken } from '@/modules/auth'
import { buildRealtimeAgent } from '@/modules/buildRealtimeAgent'
import { playReadyChime } from '@/modules/readyChime'
import { startThinkingSound, stopThinkingSound } from '@/modules/thinkingSound'
import { getRealtimeClientSecret, transcribeAudio } from '@/lib/api'
import { RealtimeSession } from '@openai/agents/realtime'
import { OpenAIRealtimeWebRTC } from '@openai/agents-realtime'
import config from '@/config.json'
import { usePrefsStore } from '@/stores/prefsStore'
import { WORKER_URL } from '@/config/worker-url'

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
let _ttsOverride: TtsService | null = null

/** Test-only seam. Production code never sets this. */
export function setTestTtsService(override: TtsService | null): void {
  _ttsOverride = override
}

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
  if (_ttsOverride) return _ttsOverride
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
      workerUrl: WORKER_URL,
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
        findBookByHash: (hash) => window.electron.findBookByHash(hash),
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
          window.electron.booksUpdateFileHash(bookId, hash, r2Key),
        getFileSize
      },
      rag: getRagService(),
      embed: embedWithFallback,
      scanner,
      config: {
        copyTimeoutMs: 2 * 60 * 1000,
        hashTimeoutMs: 30 * 1000,
        parseTimeoutMs: 60 * 1000,
        saveTimeoutMs: 30 * 1000,
        embedBatchSize: 2
      }
    })
  }
  return _import
}

let _voiceChat: VoiceChatService | null = null

// Single source of truth for VAD knobs — the vad port closure and the
// VoiceChatConfig.localVad/serverVad fields both reference these, so future
// tuning at one site doesn't silently leave the other stale.
const VOICE_CHAT_LOCAL_VAD: LocalVadConfig = {
  rmsThreshold: 0.05,
  hangoverMs: 700,
  pollIntervalMs: 50,
  fftSize: 256
}
const VOICE_CHAT_SERVER_VAD: ServerVadConfig = {
  threshold: 0.7,
  silenceDurationMs: 700,
  prefixPaddingMs: 300
}

export function getVoiceChatService(): VoiceChatService {
  if (!_voiceChat) {
    _voiceChat = createVoiceChatService({
      rag: getRagService(),
      connectivity: getConnectivityService(),
      ipc: { getRealtimeClientSecret, transcribeAudio },
      webrtcFactory: ({ mediaStream, audioElement }) =>
        new OpenAIRealtimeWebRTC({
          mediaStream: mediaStream as unknown as MediaStream,
          audioElement: audioElement as unknown as HTMLAudioElement
        }) as never,
      agentFactory: ({
        bookId,
        pageText,
        outline,
        activeParagraphText,
        visualSummary,
        onEndConversation,
        onInspectImage,
        rag,
        language
      }) =>
        buildRealtimeAgent({
          bookId,
          pageText,
          outline,
          activeParagraphText,
          visualSummary,
          onEndConversation,
          onInspectImage,
          rag,
          language
        }) as never,
      sessionFactory: (agent, opts) =>
        new RealtimeSession(agent as never, {
          transport: opts.transport as never,
          apiKey: opts.apiKey,
          // GA path: config.audio.input.turnDetection. Raised threshold +
          // longer silence_duration than OpenAI's defaults so brief sounds,
          // breaths, and accidental syllables don't trigger turn boundaries.
          config: {
            audio: {
              input: {
                turnDetection: {
                  type: 'server_vad',
                  threshold: opts.serverVad.threshold,
                  silenceDurationMs: opts.serverVad.silenceDurationMs,
                  prefixPaddingMs: opts.serverVad.prefixPaddingMs
                }
              }
            }
          }
        } as never) as never,
      media: {
        getUserMedia: (constraints) => navigator.mediaDevices.getUserMedia(constraints),
        createAudioElement: () => {
          const a = document.createElement('audio')
          a.autoplay = true
          return a
        },
        createMediaRecorder: (stream) => {
          if (typeof MediaRecorder === 'undefined') return null
          // Prefer Opus-in-WebM (Deepgram accepts it directly); fall back to
          // the platform default if the codec isn't supported.
          const preferred = 'audio/webm;codecs=opus'
          const options =
            MediaRecorder.isTypeSupported(preferred) ? { mimeType: preferred } : undefined
          try {
            return new MediaRecorder(
              stream as unknown as MediaStream,
              options
            ) as unknown as MediaRecorderLike
          } catch {
            return null
          }
        },
        cloneStreamForWebrtcSend: (source) => {
          // Independent `enabled` flag from the source's tracks, so the SDK's
          // `peerConnection.addTrack(stream.getAudioTracks()[0])` adds a track
          // that is muted at the source until the activation pipeline calls
          // `session.mute(false)`. Cloning is necessary because muting the
          // shared track would also kill MediaRecorder + local VAD input.
          const sourceStream = source as unknown as MediaStream
          const clonedTracks = sourceStream.getAudioTracks().map((t) => {
            const clone = t.clone()
            clone.enabled = false
            return clone
          })
          return new MediaStream(clonedTracks)
        }
      },
      vad: {
        create: (stream) => createLocalVad(stream, VOICE_CHAT_LOCAL_VAD)
      },
      effects: { playReadyChime, startThinkingSound, stopThinkingSound },
      clock: {
        now: () => Date.now(),
        setTimeout: (fn, ms) => setTimeout(fn, ms),
        clearTimeout: (handle) => clearTimeout(handle)
      },
      network: {
        // Idempotent <link rel="preconnect"> for the OpenAI realtime API host.
        // Chromium's resource hints pool the resulting HTTP/2 connection for
        // ~5 min, so the SDP exchange in OpenAIRealtimeWebRTC.connect() can
        // skip the cold DNS + TCP + TLS handshake (typically 150–300ms).
        // crossOrigin = 'anonymous' matches the SDK's later cross-origin fetch
        // — without it Chromium opens a SEPARATE connection for the actual
        // request and the preconnect is wasted. The link element is left in
        // place: it's <100 bytes of DOM, and removing it would risk dropping
        // the warmed connection from the pool before activate() runs.
        preconnectOpenAI: () => {
          const href = 'https://api.openai.com'
          if (document.head.querySelector(`link[rel="preconnect"][href="${href}"]`)) return
          const link = document.createElement('link')
          link.rel = 'preconnect'
          link.href = href
          link.crossOrigin = 'anonymous'
          document.head.appendChild(link)
        }
      },
      config: {
        // Auto-close after 3 minutes of no agent activity. Prevents a user
        // leaving voice chat on from racking up open-ended audio billing.
        inactivityTimeoutMs: 3 * 60 * 1000,
        connectTimeoutMs: 60 * 1000,
        keyTtlMs: 9 * 60 * 1000,
        // Capture speech uttered during the connect window and inject as a
        // text message once the session is live. Set to false to disable
        // without a code change if the feature regresses in production.
        bufferedSpeechReplayEnabled: true,
        localVad: VOICE_CHAT_LOCAL_VAD,
        // Raised from OpenAI's default 0.5 → 0.7 to make server-side turn
        // detection less twitchy. silenceDurationMs/prefixPaddingMs widen the
        // window so brief mid-sentence pauses don't end turns prematurely.
        serverVad: VOICE_CHAT_SERVER_VAD
      },
      getLanguage: () => usePrefsStore.getState().voiceChatLanguage
    })
    _voiceChat.start()
    // Fire-and-forget: hydration is sub-50ms; if a chat starts before it
    // resolves, the store returns the default 'en'. Catch logs but does
    // not surface — a failure here just leaves the user on the default.
    void usePrefsStore
      .getState()
      .hydrate()
      .catch((err) => {
        console.warn('[prefs] hydrate failed', err)
      })
  }
  return _voiceChat
}
