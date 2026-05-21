/**
 * Shared TTS service factory. Ported from
 * `apps/rishi-electron/src/renderer/src/services/tts/service.ts`.
 *
 * Key change vs electron: audio bytes → URI conversion is now an
 * injected port (`makeAudioUri`), because `URL.createObjectURL` /
 * `Blob` aren't available on React Native. Electron callers use the
 * default which preserves the blob-URL behaviour.
 */
import type {
  AudioErrorEvent,
  AudioReadyEvent,
  AudioRequest,
  QueueStatus,
  TtsService,
  TtsServiceDeps
} from './types'
import { createCache } from './cache'
import { createEmitter } from './emitter'
import { makeProgram } from './program'

function defaultMakeAudioUri(bytes: Uint8Array): Promise<string> {
  // Web/electron path. URL + Blob exist in both. RN must inject its own port.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const G = globalThis as any
  if (typeof G.URL?.createObjectURL !== 'function' || typeof G.Blob !== 'function') {
    throw new Error(
      '[tts] no URL.createObjectURL/Blob available — pass `deps.makeAudioUri` (mobile)'
    )
  }
  return Promise.resolve(G.URL.createObjectURL(new G.Blob([bytes], { type: 'audio/mpeg' })))
}

export function createTtsService(deps: TtsServiceDeps): TtsService {
  const cache = createCache({ ipc: deps.ipc, cacheMaxBytes: deps.config.cacheMaxBytes })
  const audioReady = createEmitter<AudioReadyEvent>()
  const errors = createEmitter<AudioErrorEvent>()
  const makeUri = deps.makeAudioUri ?? defaultMakeAudioUri

  const program = makeProgram({
    cache,
    fetch: deps.fetch,
    getAuthToken: deps.getAuthToken,
    config: deps.config
  })

  async function requestAudio(req: AudioRequest): Promise<string> {
    const priority = req.priority ?? 0
    try {
      const cached = await cache.getAudio(req.bookId, req.cfiRange, req.text)
      if (cached) {
        const url = await makeUri(new Uint8Array(cached), {
          bookId: req.bookId,
          cfiRange: req.cfiRange
        })
        audioReady.emit({ bookId: req.bookId, cfiRange: req.cfiRange, audioPath: url })
        return url
      }
      const bytes = await program.submit({
        bookId: req.bookId,
        cfiRange: req.cfiRange,
        text: req.text,
        priority
      })
      const url = await makeUri(new Uint8Array(bytes), {
        bookId: req.bookId,
        cfiRange: req.cfiRange
      })
      audioReady.emit({ bookId: req.bookId, cfiRange: req.cfiRange, audioPath: url })
      return url
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      errors.emit({ bookId: req.bookId, cfiRange: req.cfiRange, error: message })
      throw err
    }
  }

  return {
    requestAudio,
    cancelRequest(bookId, cfiRange) {
      return program.cancel(`${bookId}-${cfiRange}`)
    },
    cancelBookRequests(bookId) {
      program.cancelBook(bookId)
    },
    async clearBookCache(bookId) {
      try {
        await cache.clearBook(bookId)
      } catch (err) {
        console.warn(`[tts] clearBookCache failed: ${String(err)}`)
      }
    },
    getQueueStatus(): QueueStatus {
      return program.status()
    },
    onAudioReady(cb) {
      return audioReady.on(cb)
    },
    onError(cb) {
      return errors.on(cb)
    }
  }
}
