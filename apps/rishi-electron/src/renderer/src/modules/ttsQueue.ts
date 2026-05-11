/**
 * TTS Queue Manager
 * Handles queuing and processing of text-to-speech requests with OpenAI API.
 * Ported from Tauri version, uses eventemitter3 + standard fetch for browser.
 */
import EventEmitter from 'eventemitter3'
import PriorityQueue from 'priorityqueuejs'
import type { TTSRequest } from '@/types'
import { ttsCache } from './ttsCache'
import { TTSQueueEvents } from './ipc_handles'
import { getAuthToken } from './auth'
import config from '@/config.json'
import { logStateEvent } from '@/utils/stateDump'
import { captureError } from '@/utils/sentry'

/** Safely extract a human-readable message from any thrown value. */
function toErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === 'string') return error
  try {
    return JSON.stringify(error)
  } catch {
    return String(error)
  }
}

/** Wrap any thrown value in a proper Error instance. */
function toError(error: unknown): Error {
  if (error instanceof Error) return error
  return new Error(toErrorMessage(error))
}

export interface QueueItem extends TTSRequest {
  priority: number
  resolve: (audioPath: string) => void
  reject: (error: Error) => void
  requestId: string
  timestamp: number
  retryCount: number
}

/**
 * TTS Queue Manager
 * Handles queuing and processing of text-to-speech requests with OpenAI API
 */
export class TTSQueue extends EventEmitter {
  private queue: PriorityQueue<QueueItem>

  private readonly activeRequests = new Map<string, QueueItem>()
  private readonly pendingRequests = new Map<string, QueueItem>()
  private readonly pendingTimeouts = new Set<ReturnType<typeof setTimeout>>()
  private readonly MAX_RETRIES = 3
  private readonly RETRY_DELAY_MS = 1000
  private readonly REQUEST_TIMEOUT_MS = 1 * 60 * 1000
  private readonly MAX_QUEUE_SIZE = 15
  /** Max concurrent HTTP requests to the TTS API */
  private readonly MAX_CONCURRENCY = 8
  /** Number of slots currently occupied by in-flight requests */
  private inFlightCount = 0

  constructor() {
    super()

    /**
     * Initialize priority queue with custom comparator (higher priority first)
     */
    this.queue = new PriorityQueue((a: QueueItem, b: QueueItem) => b.priority - a.priority)
  }

  /**
   * Trim lowest-priority items when queue is full.
   * Rebuilds the queue keeping only the top MAX_QUEUE_SIZE-1 items.
   */
  private trimQueueIfNeeded(): void {
    if (this.queue.size() < this.MAX_QUEUE_SIZE) return

    // Drain all items, keep the highest-priority ones
    const items: QueueItem[] = []
    while (this.queue.size() > 0) {
      items.push(this.queue.deq())
    }

    // items are already sorted highest-priority-first (deq order)
    const kept = items.slice(0, this.MAX_QUEUE_SIZE - 1)
    const dropped = items.slice(this.MAX_QUEUE_SIZE - 1)

    // Re-enqueue kept items
    for (const item of kept) {
      this.queue.enq(item)
    }

    // Reject dropped items so their promises don't leak
    for (const item of dropped) {
      this.pendingRequests.delete(item.requestId)
      item.reject(new Error('Dropped from queue (low priority)'))

      // Emit error so duplicate listeners in the service layer also get notified
      this.emit(TTSQueueEvents.AUDIO_ERROR, {
        bookId: item.bookId,
        cfiRange: item.cfiRange,
        error: 'Dropped from queue (low priority)',
        requestId: item.requestId
      })
    }
  }

  /**
   * Add a TTS request to the queue (cache check should be done by caller)
   */
  requestAudio(bookId: string, cfiRange: string, text: string, priority = 0): Promise<string> {
    this.emit(TTSQueueEvents.REQUEST_AUDIO, {
      bookId,
      cfiRange,
      text,
      priority
    })

    // Trim queue inline to prevent unbounded growth
    this.trimQueueIfNeeded()

    // Create unique request ID for deduplication
    const requestId = `${bookId}-${cfiRange}`

    // Check for duplicate request
    if (this.pendingRequests.has(requestId)) {
      return new Promise((resolve, reject) => {
        const cleanup = () => {
          clearTimeout(timeout)
          this.off(TTSQueueEvents.AUDIO_READY, handleAudioReady)
          this.off(TTSQueueEvents.AUDIO_ERROR, handleAudioError)
        }

        // Listen for audio-ready events and filter by requestId
        const handleAudioReady = (data: {
          bookId: string
          cfiRange: string
          audioPath: string
          requestId: string
        }) => {
          if (data.requestId === requestId) {
            cleanup()
            resolve(data.audioPath)
          }
        }

        const handleAudioError = (data: {
          bookId: string
          cfiRange: string
          error: Error
          requestId: string
        }) => {
          if (data.requestId === requestId) {
            cleanup()
            reject(data.error)
          }
        }

        // Timeout to prevent listener leak if the event is never emitted
        const timeout = setTimeout(() => {
          cleanup()
          reject(new Error('TTS duplicate request timed out'))
        }, this.REQUEST_TIMEOUT_MS)

        this.on(TTSQueueEvents.AUDIO_READY, handleAudioReady)
        this.on(TTSQueueEvents.AUDIO_ERROR, handleAudioError)
      })
    }

    // Return a promise that resolves when the audio is generated
    return new Promise<string>((resolve, reject) => {
      const queueItem: QueueItem = {
        bookId,
        cfiRange,
        text,
        priority,
        resolve,
        reject,
        requestId,
        timestamp: Date.now(),
        retryCount: 0
      }

      // Add item to priority queue (automatically sorted by priority)
      this.queue.enq(queueItem)
      // Store in pending requests map
      this.pendingRequests.set(requestId, queueItem)

      // Fill any free concurrency slots
      this.fillSlots()
    })
  }

  /**
   * Fill free concurrency slots with the highest-priority queued items.
   * Each slot operates independently — when it finishes, it immediately
   * picks the next highest-priority item, so a priority-1 playback request
   * only waits for one slot to free up instead of an entire batch.
   */
  private fillSlots(): void {
    while (this.inFlightCount < this.MAX_CONCURRENCY && this.queue.size() > 0) {
      const item = this.queue.deq()
      this.inFlightCount++
      void this.processItem(item).finally(() => {
        this.inFlightCount--
        // Immediately pick up the next item when this slot frees
        this.fillSlots()
      })
    }
  }

  /**
   * Process a single queue item: generate audio, cache it, resolve/reject.
   */
  private async processItem(item: QueueItem): Promise<void> {
    // Check if request is too old and should be cancelled
    if (Date.now() - item.timestamp > this.REQUEST_TIMEOUT_MS) {
      this.pendingRequests.delete(item.requestId)
      item.reject(new Error('Request timeout'))
      return
    }

    // Track active request
    this.activeRequests.set(item.requestId, item)

    try {
      const audioData = await this.generateAudio(item)

      let audioPath: string
      try {
        // In Electron, save audio as blob and create a blob URL for playback.
        // Also save to disk cache (fire-and-forget) for persistence.
        const blob = new Blob([audioData.buffer as ArrayBuffer], { type: 'audio/mpeg' })

        void ttsCache
          .saveCachedAudio(item.bookId, item.cfiRange, blob, item.text)
          .catch((cacheErr) => console.warn(`Cache write failed: ${toErrorMessage(cacheErr)}`))

        audioPath = URL.createObjectURL(blob)
      } catch (cacheErr) {
        // Cache write failed -- create a blob URL so the audio can still play.
        console.warn(`Cache write failed, using blob URL: ${toErrorMessage(cacheErr)}`)
        const blob = new Blob([audioData.buffer as ArrayBuffer], { type: 'audio/mpeg' })
        audioPath = URL.createObjectURL(blob)
      }

      // Clean up tracking
      this.pendingRequests.delete(item.requestId)
      this.activeRequests.delete(item.requestId)

      // Resolve the promise and emit events
      item.resolve(audioPath)

      // Emit audio-ready event with requestId for duplicate listeners
      this.emit(TTSQueueEvents.AUDIO_READY, {
        bookId: item.bookId,
        cfiRange: item.cfiRange,
        audioPath,
        requestId: item.requestId
      })
    } catch (error) {
      const errorMsg = toErrorMessage(error)
      console.error('>>> Queue: Error processing item', {
        requestId: item.requestId,
        error: errorMsg
      })
      // Clean up tracking
      this.pendingRequests.delete(item.requestId)
      this.activeRequests.delete(item.requestId)

      // Handle retry logic
      if (item.retryCount < this.MAX_RETRIES && this.isRetryableError(error)) {
        console.warn(`Retrying request ${item.requestId} (attempt ${item.retryCount + 1})`)
        item.retryCount++

        // Add back to queue with delay, then fill slots
        const timeout = setTimeout(
          () => {
            this.queue.enq(item)
            this.pendingRequests.set(item.requestId, item)
            this.pendingTimeouts.delete(timeout)
            this.fillSlots()
          },
          this.RETRY_DELAY_MS * Math.pow(2, item.retryCount - 1)
        ) // Exponential backoff

        this.pendingTimeouts.add(timeout)
      } else {
        const wrappedError = toError(error)
        item.reject(wrappedError)

        // Emit audio-error event with requestId for duplicate listeners
        this.emit(TTSQueueEvents.AUDIO_ERROR, {
          bookId: item.bookId,
          cfiRange: item.cfiRange,
          error: errorMsg,
          requestId: item.requestId
        })

        captureError(wrappedError, {
          operation: 'tts-generation',
          step: 'processItem',
          requestId: item.requestId,
          bookId: item.bookId,
          retryCount: item.retryCount,
          textLength: item.text.length
        })

        console.error(`TTS generation failed for ${item.requestId}: ${errorMsg}`)
      }
    }
  }

  /**
   * Generate audio using OpenAI TTS API
   */
  async generateAudio(item: QueueItem): Promise<Uint8Array> {
    const url = config.production.audio_worker_url

    logStateEvent('ttsQueue.generateAudio', {
      requestId: item.requestId,
      url,
      textLength: item.text.length,
      retryCount: item.retryCount
    })

    try {
      // OpenAI TTS API has a 4096 character limit per request
      const truncatedText = item.text.length > 4000 ? item.text.slice(0, 4000) + '…' : item.text
      const requestBody = {
        voice: 'alloy',
        input: truncatedText,
        response_format: 'mp3',
        speed: 1.0
      }

      let token: string | null
      try {
        token = await getAuthToken()
      } catch (authErr) {
        throw new Error(`Authentication failed: ${toErrorMessage(authErr)}`)
      }

      const headers: Record<string, string> = {
        'Content-Type': 'application/json'
      }

      if (token) {
        headers['Authorization'] = `Bearer ${token}`
      } else {
        // No Clerk session — fall back to the dev bypass secret if configured
        const devBypassSecret = await window.electron.getDevBypassSecret()
        if (devBypassSecret) {
          headers['X-Dev-Bypass'] = devBypassSecret
        } else {
          throw new Error('Not authenticated -- sign in to use text-to-speech')
        }
      }

      const ttsController = new AbortController()
      const ttsTimeout = setTimeout(() => ttsController.abort(), 30_000)
      let response: Response
      try {
        response = await fetch(url, {
          method: 'POST',
          headers,
          body: JSON.stringify(requestBody),
          signal: ttsController.signal
        })
      } catch (err) {
        if (ttsController.signal.aborted) {
          throw new Error('TTS request timed out after 30 seconds')
        }
        throw err
      } finally {
        clearTimeout(ttsTimeout)
      }

      logStateEvent('ttsQueue.response', {
        requestId: item.requestId,
        status: response.status,
        ok: response.ok
      })

      if (!response.ok) {
        const errorText = await response.text().catch(() => 'Could not read error text')
        const bodyExcerpt = errorText.slice(0, 500)
        console.error('>>> Queue: API returned error', {
          requestId: item.requestId,
          status: response.status,
          statusText: response.statusText,
          errorText
        })
        const httpErr = new Error(
          `OpenAI TTS API error: ${response.status} ${response.statusText} - ${errorText}`
        )
        captureError(httpErr, {
          operation: 'tts-generation',
          step: 'http_response',
          requestId: item.requestId,
          httpStatus: response.status,
          httpStatusText: response.statusText,
          bodyExcerpt,
          authMode: headers['Authorization'] ? 'bearer' : 'dev-bypass',
          hasToken: Boolean(token),
          isPackaged: import.meta.env.PROD,
          workerUrl: url
        })
        throw httpErr
      }

      // Convert response to buffer
      const audioData = new Uint8Array(await response.arrayBuffer())

      if (audioData.length === 0) {
        throw new Error('OpenAI TTS API returned empty audio buffer')
      }

      return audioData
    } catch (error) {
      const errorMsg = toErrorMessage(error)
      console.error('>>> Queue: Audio generation failed', {
        requestId: item.requestId,
        url,
        textLength: item.text.length,
        retryCount: item.retryCount,
        error: errorMsg
      })

      throw new Error(`TTS API error: ${errorMsg}`)
    }
  }

  /**
   * Clear all pending requests
   */
  clearQueue(): void {
    // Clear queue
    while (!this.queue.isEmpty()) {
      const item = this.queue.deq()
      this.pendingRequests.delete(item.requestId)
      item.reject(new Error('Queue cleared'))
    }

    // Clear active requests
    for (const [requestId, item] of this.activeRequests) {
      this.pendingRequests.delete(requestId)
      item.reject(new Error('Request cancelled'))
    }
    this.activeRequests.clear()

    // Clear pending timeouts
    for (const timeout of this.pendingTimeouts) {
      clearTimeout(timeout)
    }
    this.pendingTimeouts.clear()
  }

  /**
   * Cancel a specific request
   */
  cancelRequest(requestId: string): boolean {
    // Check active requests
    if (this.activeRequests.has(requestId)) {
      const item = this.activeRequests.get(requestId)!
      this.activeRequests.delete(requestId)
      this.pendingRequests.delete(requestId)
      item.reject(new Error('Request cancelled'))
      return true
    }

    // Check pending requests map
    if (this.pendingRequests.has(requestId)) {
      const item = this.pendingRequests.get(requestId)!
      this.pendingRequests.delete(requestId)
      item.reject(new Error('Request cancelled'))
      // Emit error event for any duplicate listeners
      this.emit(TTSQueueEvents.AUDIO_ERROR, {
        bookId: item.bookId,
        cfiRange: item.cfiRange,
        error: 'Request cancelled',
        requestId: requestId
      })
      return true
    }

    return false
  }

  /**
   * Check if an error is retryable
   */
  private isRetryableError(error: unknown): boolean {
    const errorMessage =
      error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase()

    return (
      errorMessage.includes('timeout') ||
      errorMessage.includes('network') ||
      errorMessage.includes('rate limit') ||
      errorMessage.includes('server error') ||
      errorMessage.includes('temporary') ||
      errorMessage.includes('connection') ||
      errorMessage.includes('econnreset')
    )
  }

  /**
   * Get current queue status
   */
  getQueueStatus(): { pending: number; isProcessing: boolean; active: number } {
    return {
      pending: this.queue.size(),
      isProcessing: this.inFlightCount > 0,
      active: this.activeRequests.size
    }
  }
}

// Export singleton instance
export const ttsQueue = new TTSQueue()
