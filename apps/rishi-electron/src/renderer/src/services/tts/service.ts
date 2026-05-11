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

export function createTtsService(deps: TtsServiceDeps): TtsService {
  const cache = createCache({ ipc: deps.ipc, cacheMaxBytes: deps.config.cacheMaxBytes })
  const audioReady = createEmitter<AudioReadyEvent>()
  const errors = createEmitter<AudioErrorEvent>()

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
        const url = URL.createObjectURL(new Blob([cached], { type: 'audio/mpeg' }))
        audioReady.emit({ bookId: req.bookId, cfiRange: req.cfiRange, audioPath: url })
        return url
      }
      const bytes = await program.submit({
        bookId: req.bookId,
        cfiRange: req.cfiRange,
        text: req.text,
        priority
      })
      const url = URL.createObjectURL(new Blob([bytes], { type: 'audio/mpeg' }))
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
