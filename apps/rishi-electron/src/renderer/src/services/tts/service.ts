import type {
  AudioErrorEvent,
  AudioReadyEvent,
  AudioRequest,
  QueueStatus,
  TtsService,
  TtsServiceDeps
} from './types'
import { createCache } from './cache'
import { createQueue } from './queue'
import { fetchAudio as transportFetchAudio } from './transport'
import { createEmitter } from './emitter'

export function createTtsService(deps: TtsServiceDeps): TtsService {
  const cache = createCache({ ipc: deps.ipc, cacheMaxBytes: deps.config.cacheMaxBytes })
  const audioReady = createEmitter<AudioReadyEvent>()
  const errors = createEmitter<AudioErrorEvent>()

  const queue = createQueue({
    cache,
    fetchAudio: async (text) => {
      const auth = await deps.getAuthToken()
      return transportFetchAudio({
        fetch: deps.fetch,
        auth,
        config: deps.config,
        text
      })
    },
    maxConcurrent: deps.config.maxConcurrent,
    maxRetries: 3,
    backoffBaseMs: 1000
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
      const bytes = await queue.enqueue({
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
      return queue.cancel(`${bookId}-${cfiRange}`)
    },
    cancelBookRequests(bookId) {
      queue.cancelBook(bookId)
    },
    async clearBookCache(bookId) {
      try {
        await cache.clearBook(bookId)
      } catch (err) {
        console.warn(`[tts] clearBookCache failed: ${String(err)}`)
      }
    },
    getQueueStatus(): QueueStatus {
      return queue.status()
    },
    onAudioReady(cb) {
      return audioReady.on(cb)
    },
    onError(cb) {
      return errors.on(cb)
    }
  }
}
