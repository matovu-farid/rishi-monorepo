import PriorityQueue from 'priorityqueuejs'
import type { Cache } from './cache'
import { TtsTransportError } from './transport'

export interface EnqueueArgs {
  bookId: string
  cfiRange: string
  text: string
  priority: number
}

export interface QueueDeps {
  cache: Pick<Cache, 'getAudio' | 'saveAudio' | 'evictIfNeeded'>
  /**
   * Transport callable. The queue does not know about auth/config — it just
   * forwards the text and gets bytes back (or a TtsTransportError).
   */
  fetchAudio: (text: string) => Promise<ArrayBuffer>
  maxConcurrent: number
  maxRetries: number
  /** Backoff = backoffBaseMs * 2^attempt. */
  backoffBaseMs: number
}

interface QueueItem {
  bookId: string
  cfiRange: string
  text: string
  priority: number
  requestId: string
  resolve: (bytes: ArrayBuffer) => void
  reject: (err: Error) => void
  retryCount: number
}

const MAX_QUEUE_SIZE = 15

export interface Queue {
  enqueue(req: EnqueueArgs): Promise<ArrayBuffer>
  cancel(requestId: string): boolean
  cancelBook(bookId: string): void
  clear(): void
  status(): { pending: number; isProcessing: boolean; active: number }
}

export function createQueue(deps: QueueDeps): Queue {
  const pq = new PriorityQueue<QueueItem>((a, b) => b.priority - a.priority)
  const active = new Map<string, QueueItem>()
  /** All in-flight or queued items, keyed by requestId, for dedup. */
  const pending = new Map<string, QueueItem>()
  const retryTimers = new Set<ReturnType<typeof setTimeout>>()
  let inFlight = 0

  function fillSlots(): void {
    while (inFlight < deps.maxConcurrent && pq.size() > 0) {
      const item = pq.deq()
      inFlight++
      active.set(item.requestId, item)
      void processItem(item).finally(() => {
        inFlight--
        active.delete(item.requestId)
        fillSlots()
      })
    }
  }

  async function processItem(item: QueueItem): Promise<void> {
    try {
      const bytes = await deps.fetchAudio(item.text)
      void deps.cache
        .saveAudio(item.bookId, item.cfiRange, new Uint8Array(bytes))
        .catch(() => {})
      void deps.cache.evictIfNeeded().catch(() => {})
      pending.delete(item.requestId)
      item.resolve(bytes)
    } catch (err) {
      const retryable =
        err instanceof TtsTransportError ? err.retryable : isRetryableMessage(err)
      if (retryable && item.retryCount < deps.maxRetries) {
        item.retryCount++
        const delay = deps.backoffBaseMs * 2 ** (item.retryCount - 1)
        const t = setTimeout(() => {
          retryTimers.delete(t)
          pq.enq(item)
          fillSlots()
        }, delay)
        retryTimers.add(t)
      } else {
        pending.delete(item.requestId)
        item.reject(err instanceof Error ? err : new Error(String(err)))
      }
    }
  }

  function isRetryableMessage(err: unknown): boolean {
    const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase()
    return /timeout|network|rate limit|server error|temporary|connection|econnreset/.test(msg)
  }

  function trimIfNeeded(): void {
    if (pq.size() < MAX_QUEUE_SIZE) return
    const items: QueueItem[] = []
    while (pq.size() > 0) items.push(pq.deq())
    const kept = items.slice(0, MAX_QUEUE_SIZE - 1)
    const dropped = items.slice(MAX_QUEUE_SIZE - 1)
    for (const i of kept) pq.enq(i)
    for (const d of dropped) {
      pending.delete(d.requestId)
      d.reject(new Error('Dropped from queue (low priority)'))
    }
  }

  return {
    enqueue(req) {
      const requestId = `${req.bookId}-${req.cfiRange}`
      const existing = pending.get(requestId)
      if (existing) {
        // Dedup: piggy-back on the existing item's resolution.
        return new Promise<ArrayBuffer>((resolve, reject) => {
          const origResolve = existing.resolve
          const origReject = existing.reject
          existing.resolve = (bytes) => {
            origResolve(bytes)
            resolve(bytes)
          }
          existing.reject = (err) => {
            origReject(err)
            reject(err)
          }
        })
      }
      return new Promise<ArrayBuffer>((resolve, reject) => {
        const item: QueueItem = {
          bookId: req.bookId,
          cfiRange: req.cfiRange,
          text: req.text,
          priority: req.priority,
          requestId,
          resolve,
          reject,
          retryCount: 0
        }
        pq.enq(item)
        pending.set(requestId, item)
        trimIfNeeded()
        fillSlots()
      })
    },
    cancel(requestId) {
      const item = pending.get(requestId)
      if (!item) return false
      pending.delete(requestId)
      active.delete(requestId)
      item.reject(new Error('Request cancelled'))
      return true
    },
    cancelBook(bookId) {
      for (const [requestId, item] of [...pending]) {
        if (item.bookId === bookId) {
          pending.delete(requestId)
          active.delete(requestId)
          item.reject(new Error('Request cancelled'))
        }
      }
    },
    clear() {
      for (const t of retryTimers) clearTimeout(t)
      retryTimers.clear()
      while (pq.size() > 0) {
        const item = pq.deq()
        pending.delete(item.requestId)
        item.reject(new Error('Queue cleared'))
      }
      for (const [, item] of active) item.reject(new Error('Request cancelled'))
      active.clear()
      pending.clear()
    },
    status() {
      return {
        pending: pq.size(),
        isProcessing: inFlight > 0,
        active: active.size
      }
    }
  }
}
