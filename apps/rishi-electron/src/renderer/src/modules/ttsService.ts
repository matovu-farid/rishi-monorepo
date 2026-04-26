/**
 * TTS Service - coordinates cache and queue operations.
 * Ported from Tauri version, uses eventemitter3 for browser compatibility.
 */
import EventEmitter from 'eventemitter3'
import { ttsQueue } from './ttsQueue'
import { ttsCache } from './ttsCache'
import { TTS_EVENTS, TTSQueueEvents } from './ipc_handles'
import { captureError } from '../utils/sentry'

export interface AudioReadyEvent {
  bookId: string
  cfiRange: string
  audioPath: string
}

export interface TTSErrorEvent {
  bookId: string
  cfiRange: string
  error: string
}

export type TTSServiceEventMap = {
  [TTS_EVENTS.AUDIO_READY]: [AudioReadyEvent]
  [TTS_EVENTS.ERROR]: [TTSErrorEvent]
}

export class TTSService extends EventEmitter {
  private readonly activeRequests = new Set<string>()
  private readonly pendingListeners = new Map<
    string,
    {
      timeout: ReturnType<typeof setTimeout>
      listeners: Array<{
        onAudioReady: (event: AudioReadyEvent) => void
        onError: (event: TTSErrorEvent) => void
      }>
    }
  >()
  private readonly LISTENER_TIMEOUT_MS = 30000 // 30 seconds timeout for listeners

  constructor() {
    super()

    // Forward audio-ready events from queue
    ttsQueue.on(TTSQueueEvents.AUDIO_READY, (event: AudioReadyEvent) => {
      this.activeRequests.delete(`${event.bookId}-${event.cfiRange}`)
      this.emit(TTS_EVENTS.AUDIO_READY, event)
    })

    // Forward error events from queue
    ttsQueue.on(TTSQueueEvents.AUDIO_ERROR, (event: TTSErrorEvent) => {
      this.activeRequests.delete(`${event.bookId}-${event.cfiRange}`)
      this.emit(TTS_EVENTS.ERROR, event)
    })
  }

  /**
   * Request audio for a paragraph.
   * Checks cache first, then queues for generation if not cached.
   */
  async requestAudio(
    bookId: string,
    cfiRange: string,
    text: string,
    priority = 0
  ): Promise<string> {
    const requestId = `${bookId}-${cfiRange}`

    try {
      // Check if request is already active
      if (this.activeRequests.has(requestId)) {
        // Return a promise that will resolve when the active request completes
        return new Promise((resolve, reject) => {
          const onAudioReady = (event: AudioReadyEvent) => {
            if (event.bookId === bookId && event.cfiRange === cfiRange) {
              this.cleanupPendingListener(requestId)
              resolve(event.audioPath)
            }
          }

          const onError = (event: TTSErrorEvent) => {
            if (event.bookId === bookId && event.cfiRange === cfiRange) {
              console.error('>>> Service: Active request failed', {
                requestId,
                error: event.error
              })
              this.cleanupPendingListener(requestId)
              reject(new Error(event.error))
            }
          }

          // Setup timeout to prevent memory leaks
          const timeout = setTimeout(() => {
            console.error('>>> Service: Request timeout', {
              requestId,
              timeoutMs: this.LISTENER_TIMEOUT_MS
            })
            this.cleanupPendingListener(requestId)
            reject(new Error('Request timeout'))
          }, this.LISTENER_TIMEOUT_MS)

          // Store listener info for cleanup -- accumulate if already waiting
          const existing = this.pendingListeners.get(requestId)
          if (existing) {
            clearTimeout(existing.timeout)
            existing.timeout = timeout
            existing.listeners.push({ onAudioReady, onError })
          } else {
            this.pendingListeners.set(requestId, {
              timeout,
              listeners: [{ onAudioReady, onError }]
            })
          }

          this.on(TTS_EVENTS.AUDIO_READY, onAudioReady)
          this.on(TTS_EVENTS.ERROR, onError)
        })
      }

      // Check cache first
      try {
        const cachedData = await ttsCache.getCachedAudioData(bookId, cfiRange, text)
        if (cachedData) {
          const blob = new Blob([cachedData], { type: 'audio/mpeg' })
          return URL.createObjectURL(blob)
        }
      } catch {
        // Cache check failed -- proceed to queue
      }

      // Track active request
      this.activeRequests.add(requestId)

      // Queue for generation
      const audioPath = await ttsQueue.requestAudio(bookId, cfiRange, text, priority)

      return audioPath
    } catch (error) {
      this.activeRequests.delete(requestId)

      const errorMsg = error instanceof Error ? error.message : String(error)
      console.error(`>>> Service: TTS request failed [${requestId}]: ${errorMsg}`)

      captureError(error, {
        operation: 'tts-request',
        step: 'requestAudio',
        requestId,
        bookId,
        textLength: text.length,
        priority
      })

      // Emit error event
      this.emit(TTS_EVENTS.ERROR, {
        bookId,
        cfiRange,
        error: errorMsg
      })

      throw error
    }
  }

  /**
   * Get queue status
   */
  getQueueStatus(): { pending: number; isProcessing: boolean; active: number } {
    return ttsQueue.getQueueStatus()
  }

  /**
   * Cancel a specific request
   */
  cancelRequest(bookId: string, cfiRange: string): boolean {
    const requestId = `${bookId}-${cfiRange}`
    this.activeRequests.delete(requestId)
    return ttsQueue.cancelRequest(requestId)
  }

  /**
   * Cancel all requests for a book
   */
  cancelBookRequests(bookId: string): void {
    const requestsToCancel = Array.from(this.activeRequests).filter((id) =>
      id.startsWith(`${bookId}-`)
    )
    for (const requestId of requestsToCancel) {
      this.activeRequests.delete(requestId)
      ttsQueue.cancelRequest(requestId)
    }
  }

  /**
   * Clear book cache
   */
  async clearBookCache(bookId: string): Promise<void> {
    await ttsCache.clearBookCache(bookId)
  }

  /**
   * Get book cache size
   */
  getBookCacheSize(bookId: string): Promise<number> {
    return ttsCache.getBookCacheSize(bookId)
  }

  /**
   * Clear all pending requests
   */
  clearQueue(): void {
    // Cleanup all pending listeners
    for (const [requestId] of this.pendingListeners) {
      this.cleanupPendingListener(requestId)
    }
    this.pendingListeners.clear()
    this.activeRequests.clear()

    ttsQueue.clearQueue()
  }

  /**
   * Cleanup pending listener for a request
   */
  private cleanupPendingListener(requestId: string): void {
    const pendingListener = this.pendingListeners.get(requestId)
    if (pendingListener) {
      clearTimeout(pendingListener.timeout)
      for (const listener of pendingListener.listeners) {
        this.removeListener(TTS_EVENTS.AUDIO_READY, listener.onAudioReady)
        this.removeListener(TTS_EVENTS.ERROR, listener.onError)
      }
      this.pendingListeners.delete(requestId)
    }
  }
}

// Export singleton instance
export const ttsService = new TTSService()
