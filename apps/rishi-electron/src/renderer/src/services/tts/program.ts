import { Effect, Queue, Schedule, Ref, Fiber } from 'effect'
import {
  AuthFailedError,
  TransportError,
  ParseError,
  CancelledError,
  QueueOverflowError,
  toPublicError,
  type TtsTaggedError
} from './errors'
import type { Cache } from './cache'
import type { AuthHeader, TtsConfig } from './types'

const TTS_MAX_INPUT_CHARS = 4000
const QUEUE_CAPACITY = 15

interface WorkItem {
  requestId: string // `${bookId}-${cfiRange}`
  bookId: string
  cfiRange: string
  text: string
  priority: number
  resolve: (bytes: ArrayBuffer) => void
  reject: (err: Error) => void
}

export interface ProgramDeps {
  cache: Pick<Cache, 'saveAudio' | 'evictIfNeeded'>
  fetch: (url: string, init: RequestInit) => Promise<Response>
  getAuthToken: () => Promise<AuthHeader>
  config: TtsConfig
}

export interface Program {
  /** Submit a request. Resolves with audio bytes or rejects with a plain Error. */
  submit(args: {
    bookId: string
    cfiRange: string
    text: string
    priority: number
  }): Promise<ArrayBuffer>
  /** Interrupt the fiber for this requestId, if any. Returns true iff one was interrupted. */
  cancel(requestId: string): boolean
  /** Interrupt every fiber whose requestId starts with `${bookId}-`. */
  cancelBook(bookId: string): void
  status(): { pending: number; isProcessing: boolean; active: number }
  /** Stop the worker fiber. Used by tests for clean teardown; not currently called by service.ts. */
  shutdown(): Promise<void>
}

function buildHeaders(auth: AuthHeader): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (auth.kind === 'bearer') headers['Authorization'] = `Bearer ${auth.token}`
  else headers['X-Dev-Bypass'] = auth.secret
  return headers
}

function buildBody(text: string): string {
  const truncated =
    text.length > TTS_MAX_INPUT_CHARS ? text.slice(0, TTS_MAX_INPUT_CHARS) + '…' : text
  return JSON.stringify({
    voice: 'alloy',
    input: truncated,
    response_format: 'mp3',
    speed: 1.0
  })
}

async function makeTransportErrorFromResponse(res: Response): Promise<TransportError> {
  const errorBody = await res.text().catch(() => '')
  const retryAfterRaw = res.headers.get('Retry-After')
  const retryAfterParsed = retryAfterRaw ? Number(retryAfterRaw) * 1000 : null
  const retryAfterMs = Number.isFinite(retryAfterParsed) ? retryAfterParsed : null
  const retryable = res.status === 429 || res.status >= 500
  return new TransportError({
    status: res.status,
    retryable,
    retryAfterMs,
    message: `TTS API error ${res.status} ${res.statusText} - ${errorBody.slice(0, 500)}`
  })
}

// --- Sync Ref helpers ---
// effect v3.21 doesn't expose Ref.unsafeGet / Ref.unsafeUpdate at runtime; only
// Ref.unsafeMake. Wrap Ref.get and Ref.update with Effect.runSync so the public
// adapter (which is Promise-shaped, not Effect-shaped) can manipulate state
// synchronously.
const refGet = <A>(ref: Ref.Ref<A>): A => Effect.runSync(Ref.get(ref))
const refUpdate = <A>(ref: Ref.Ref<A>, fn: (a: A) => A): void => Effect.runSync(Ref.update(ref, fn))

// Queue.unsafeSize doesn't exist in this version either; size is async.
const queueSize = <A>(q: Queue.Queue<A>): number => Effect.runSync(Queue.size(q))

export function makeProgram(deps: ProgramDeps): Program {
  // --- Effect queues (FIFO with backpressure). Two queues for hi/lo priority. ---
  const queueHi = Effect.runSync(Queue.bounded<WorkItem>(QUEUE_CAPACITY))
  const queueLo = Effect.runSync(Queue.bounded<WorkItem>(QUEUE_CAPACITY))

  // --- Semaphore replaces the hand-rolled inFlight counter. ---
  const sem = Effect.runSync(Effect.makeSemaphore(deps.config.maxConcurrent))

  // --- Mutable shared state, all in Refs created synchronously. ---
  const pending = Ref.unsafeMake(new Map<string, WorkItem>())
  const fibers = Ref.unsafeMake(new Map<string, Fiber.RuntimeFiber<ArrayBuffer, TtsTaggedError>>())
  const inFlight = Ref.unsafeMake(0)
  const active = Ref.unsafeMake(new Set<string>())

  // --- Retry policy: exponential backoff, max 3 retries, only when the error
  //     is a retryable TransportError. ---
  const retryPolicy = Schedule.exponential('1 second', 2).pipe(
    Schedule.intersect(Schedule.recurs(3)),
    Schedule.whileInputEffect((err: TtsTaggedError) =>
      Effect.succeed(err._tag === 'TransportError' && err.retryable)
    )
  )

  const processItem = (item: WorkItem): Effect.Effect<ArrayBuffer, TtsTaggedError> =>
    Effect.gen(function* () {
      // 1. Resolve auth (any rejection → AuthFailedError, non-retryable).
      const auth = yield* Effect.tryPromise({
        try: () => deps.getAuthToken(),
        catch: (e) => new AuthFailedError({ cause: e })
      })

      // 2. POST to the TTS worker with an AbortController scoped to this Effect.
      //    On fiber interrupt, the release runs and aborts the in-flight fetch.
      const bytes = yield* Effect.acquireUseRelease(
        Effect.sync(() => new AbortController()),
        (ctrl) =>
          Effect.tryPromise({
            try: async (): Promise<ArrayBuffer> => {
              const res = await deps.fetch(deps.config.audioWorkerUrl, {
                method: 'POST',
                headers: buildHeaders(auth),
                body: buildBody(item.text),
                signal: ctrl.signal
              })
              if (!res.ok) throw await makeTransportErrorFromResponse(res)
              const buf = await res.arrayBuffer()
              if (buf.byteLength === 0) {
                throw new ParseError({ reason: 'empty audio buffer' })
              }
              return buf
            },
            catch: (e): TtsTaggedError => {
              if (e instanceof TransportError) return e
              if (e instanceof ParseError) return e
              // Anything else (network error, abort) → retryable transport.
              const message = e instanceof Error ? e.message : String(e)
              return new TransportError({
                status: null,
                retryable: true,
                retryAfterMs: null,
                message
              })
            }
          }),
        (ctrl) => Effect.sync(() => ctrl.abort())
      ).pipe(Effect.retry(retryPolicy))

      // 3. Cache write is fire-and-forget — matches Stage 1's `void deps.cache.saveAudio(...)`.
      yield* Effect.forkDaemon(
        Effect.tryPromise(() =>
          deps.cache.saveAudio(item.bookId, item.cfiRange, new Uint8Array(bytes), item.text)
        ).pipe(Effect.ignore)
      )
      yield* Effect.forkDaemon(
        Effect.tryPromise(() => deps.cache.evictIfNeeded()).pipe(Effect.ignore)
      )

      return bytes
    })

  const worker = Effect.gen(function* () {
    while (true) {
      // Prefer hi-priority queue. Effect.race takes whichever resolves first.
      const item: WorkItem = yield* Effect.race(Queue.take(queueHi), Queue.take(queueLo))

      yield* sem.withPermits(1)(
        Effect.gen(function* () {
          yield* Ref.update(inFlight, (n) => n + 1)
          yield* Ref.update(active, (s) => {
            s.add(item.requestId)
            return s
          })

          // Fork the per-item pipeline so the worker can continue draining.
          const fiber = yield* Effect.fork(
            processItem(item).pipe(
              // Success: resolve the caller's promise.
              Effect.tap((bytes) => Effect.sync(() => item.resolve(bytes))),
              // Failure: map tagged error to plain Error and reject.
              Effect.catchAll((err: TtsTaggedError) =>
                Effect.sync(() => item.reject(toPublicError(err)))
              ),
              // Interrupt: rejected as a Cancelled error. Effect.catchAllCause
              // does NOT fire on a Fiber.interrupt cause; onInterrupt does.
              Effect.onInterrupt(() =>
                Effect.sync(() => {
                  const cancelled = new CancelledError({ requestId: item.requestId })
                  item.reject(toPublicError(cancelled))
                })
              ),
              Effect.ensuring(
                Effect.gen(function* () {
                  yield* Ref.update(inFlight, (n) => Math.max(0, n - 1))
                  yield* Ref.update(active, (s) => {
                    s.delete(item.requestId)
                    return s
                  })
                  yield* Ref.update(fibers, (m) => {
                    m.delete(item.requestId)
                    return m
                  })
                  yield* Ref.update(pending, (m) => {
                    m.delete(item.requestId)
                    return m
                  })
                })
              )
            )
          )
          yield* Ref.update(fibers, (m) => {
            m.set(item.requestId, fiber as Fiber.RuntimeFiber<ArrayBuffer, TtsTaggedError>)
            return m
          })
        })
      )
    }
  })

  const workerFiber = Effect.runFork(worker)

  return {
    submit(args) {
      return new Promise<ArrayBuffer>((resolve, reject) => {
        const requestId = `${args.bookId}-${args.cfiRange}`
        const map = refGet(pending)
        const existing = map.get(requestId)
        if (existing) {
          // Dedup: chain onto the existing item's resolvers.
          const origR = existing.resolve
          const origJ = existing.reject
          existing.resolve = (b) => {
            origR(b)
            resolve(b)
          }
          existing.reject = (e) => {
            origJ(e)
            reject(e)
          }
          return
        }
        const item: WorkItem = {
          requestId,
          bookId: args.bookId,
          cfiRange: args.cfiRange,
          text: args.text,
          priority: args.priority,
          resolve,
          reject
        }
        refUpdate(pending, (m) => {
          m.set(requestId, item)
          return m
        })
        const q = args.priority >= 1 ? queueHi : queueLo
        Effect.runPromise(Queue.offer(q, item)).catch(() => {
          refUpdate(pending, (m) => {
            m.delete(requestId)
            return m
          })
          reject(toPublicError(new QueueOverflowError({ requestId })))
        })
      })
    },
    cancel(requestId) {
      const fiber = refGet(fibers).get(requestId)
      if (!fiber) {
        // Maybe still queued (not yet taken by the worker). Reject directly.
        const queued = refGet(pending).get(requestId)
        if (!queued) return false
        refUpdate(pending, (m) => {
          m.delete(requestId)
          return m
        })
        queued.reject(toPublicError(new CancelledError({ requestId })))
        return true
      }
      Effect.runFork(Fiber.interrupt(fiber))
      return true
    },
    cancelBook(bookId) {
      const prefix = `${bookId}-`
      // 1. Interrupt active fibers for this book.
      const fmap = refGet(fibers)
      for (const [rid, fiber] of fmap) {
        if (rid.startsWith(prefix)) {
          Effect.runFork(Fiber.interrupt(fiber))
        }
      }
      // 2. Reject still-queued items (no fiber yet) directly.
      const pmap = refGet(pending)
      for (const [rid, item] of [...pmap]) {
        if (rid.startsWith(prefix) && !fmap.has(rid)) {
          refUpdate(pending, (m) => {
            m.delete(rid)
            return m
          })
          item.reject(toPublicError(new CancelledError({ requestId: rid })))
        }
      }
    },
    status() {
      return {
        pending: queueSize(queueHi) + queueSize(queueLo),
        isProcessing: refGet(inFlight) > 0,
        active: refGet(active).size
      }
    },
    async shutdown() {
      await Effect.runPromise(Fiber.interrupt(workerFiber))
    }
  }
}
