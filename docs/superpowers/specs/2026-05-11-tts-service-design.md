# TTS service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](../../../../../docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 1, service #3 of 6. Stage 1 only (plain TypeScript). `apps/rishi-electron` renderer-side service that consolidates `ttsService` / `ttsQueue` / `ttsCache` / `ttsPrefetch` into one deep module.

## Goal

Collapse the current TTS quartet (`ttsService` → `ttsQueue` → `ttsCache` → `ttsPrefetch`) into one cohesive renderer-side service exposed through a small, typed interface. Hide the priority queue, the OpenAI HTTP transport, the disk cache, the dedup logic, retry/backoff, and the prefetch policy behind a ~5-method facade. Callers stop juggling four modules; they call `getTtsService().requestAudio(...)`.

## Background

TTS today is four modules in the renderer that are tightly coupled but split along arbitrary lines:

- **`ttsService.ts`** — wraps `ttsQueue` and `ttsCache`, owns an `EventEmitter` surface (`TTS_EVENTS.AUDIO_READY` / `ERROR`), tracks `activeRequests` and `pendingListeners` for dedup-by-second-call.
- **`ttsQueue.ts`** — owns the `PriorityQueue`, slot-based concurrency (`MAX_CONCURRENCY=8`), retry-with-exponential-backoff, OpenAI HTTP call (with bearer + dev-bypass header logic inline), cache write-through, dedup-by-first-call.
- **`ttsCache.ts`** — owns `userData/tts-cache/<bookId>/<md5(cfi)>.mp3` storage via 7 `window.electron.*` IPC methods, size-based LRU eviction at 500 MB / 80% threshold, dual CFI + text-hash keys.
- **`ttsPrefetch.ts`** — library-level "warm the cache for each book's open page" routine that goes through `requestTTSAudio` from `ipc_handel_functions.ts`.

Symptoms that motivated the meta-spec:

- **Dedup logic lives in two places.** `ttsQueue` dedups by `requestId` when a request is already pending. `ttsService` *also* dedups by `requestId` for active requests, with its own `pendingListeners` map, its own timeout (`LISTENER_TIMEOUT_MS=30s`, different from the queue's `REQUEST_TIMEOUT_MS=60s`), and its own cleanup. Two timeouts, two listener registries, one logical concept.
- **`EventEmitter` is a public type.** `ttsService extends EventEmitter` — every caller can subscribe to internal queue events, dispatch arbitrary events, or remove handlers. The dev-state-dump (`stateDump.ts`) reaches into `ttsQueue.getQueueStatus()` directly, bypassing the service.
- **The HTTP / auth / dev-bypass concerns are tangled into the queue.** `ttsQueue.generateAudio` reads `config.production.audio_worker_url`, calls `getAuthToken()`, queries `window.electron.getDevBypassSecret()`, and constructs the `Authorization` / `X-Dev-Bypass` headers — none of which the queue conceptually owns. Tests have to mock all three.
- **Cache lifecycle is global.** `ttsCache` is a singleton that fires `init()` at module-load time (`getAppDataPath` + `mkdir`). Importing the module for a unit test triggers IPC calls; the existing tests work around this with `vi.resetModules()` per test.
- **Prefetch is shallow.** `ttsPrefetch` is a 60-line module that calls `requestTTSAudio` (which calls `ttsService.requestAudio`) — one indirection per layer for no abstraction gain.
- **Callers wire to three different surfaces.** `usePlayerMachine` imports `ttsService` directly. `ipc_handel_functions` re-exports `requestTTSAudio` as a thin wrapper. `ttsPrefetch` uses `requestTTSAudio`. `stateDump` imports both `ttsService` and `ttsQueue`. No single entry point.

There is no single owner of "given a (book, cfi, text), give me a playable audio URL." Every layer assembles part of the pipeline.

This refactor introduces a single renderer-side TTS service that wraps cache + queue + HTTP transport + dedup, exposes a small typed interface plus a subscription API, and replaces every caller's import. `ttsPrefetch` stays as a separate file but becomes a thin consumer of the service (no transitive imports of cache/queue internals).

## Non-goals

- Changing TTS provider, voice selection, audio format, or rate-limiting semantics. Behavior preserved.
- Replacing the OpenAI-compatible worker URL. Stays `https://api.fidexa.org/api/audio/speech`.
- Adding new features (background prefetch tuning, audio-format negotiation, partial-text streaming). Scope guard per meta-spec.
- Migrating to Effect-TS. Stage 1 is plain TypeScript. Effect is the explicit Stage 2 subject for TTS (see "Stage 2 outlook" below).
- Touching the main-process IPC handlers (`mkdir`, `writeFile`, etc.). Their surface stays as-is; the service consumes them through an injected `ipc` port.

## Decision summary

| Question | Decision |
|---|---|
| Service scope | Cache + queue + HTTP transport + dedup + cancellation. Prefetch stays external. |
| Boundary | One module: `services/tts/`. Single factory `createTtsService(deps)`. |
| Public interface size | 5 methods + 1 subscribe API. No `EventEmitter` exposure. |
| Return shape | Methods return `Promise<string>` (blob URL). Subscriptions deliver typed events with `unsubscribe` returned from `on*`. |
| Dedup ownership | Single dedup point inside the service. `pendingByRequestId` map. The current dual-dedup in `ttsService` + `ttsQueue` collapses. |
| Auth / dev-bypass | Pushed *out* of the service into a `getAuthToken: () => Promise<AuthHeader>` port. Service knows nothing about Clerk vs dev-bypass. |
| HTTP transport | Injected `fetch` port (`(url, init) => Promise<Response>`) for test substitutability. |
| Config | Injected `config` port — `audioWorkerUrl`, `cacheMaxBytes`, `maxConcurrent`. No `import config from '@/config.json'` inside the service. |
| IPC | Injected `ipc` port containing exactly the 8 `window.electron.*` methods the cache uses. |
| Error model | `Promise` rejections with `Error` subclasses. No typed error channel in Stage 1. |
| Cache init | Lazy: first `requestAudio` triggers init. No top-level side-effect import. |
| Events | Small `Emitter<T>` — `service.onAudioReady(cb)` / `service.onError(cb)` return `() => void` unsubscribe handles. EventEmitter3 stays as internal impl detail. |
| Wiring site | `src/renderer/src/services/index.ts` (same wiring site introduced by the RAG service spec). Lazy singleton via `getTtsService()`. |
| `ttsPrefetch` | Stays as a separate exported helper consuming `getTtsService()`. Lives at `services/tts/prefetch.ts` for co-location. |
| Test placement | One file: `src/renderer/src/services/tts/service.test.ts`. Existing 3 test files deleted as redundant. |
| Effect adoption (Stage 2) | Justified. Scores ≥3 of 5 axes. Internal-only adoption; public interface stays plain TS. |

## Boundary

### What the service owns

- Cache reads / writes / eviction / dual-key lookup (CFI key + text-hash fallback).
- Priority queue with slot-based concurrency.
- Per-request dedup (one logical request → one HTTP call → fanout to all callers awaiting it).
- HTTP request construction, body assembly, response parsing, blob URL creation.
- Retry policy (exponential backoff, retryable-error classification, max retries).
- Cancellation (single request, all-requests-for-book, clear queue).
- Lifecycle: queue-overflow trimming, listener-leak protection via timeouts.

### What stays outside

- **Authentication.** The service calls an injected `getAuthToken()` port that returns either `{ kind: 'bearer', token }` or `{ kind: 'dev-bypass', secret }` or throws. The Clerk + dev-bypass logic lives in the caller-supplied adapter, not the service.
- **The Worker URL / cache size / concurrency knobs.** Injected via `config`.
- **The `window.electron.*` surface.** Injected via `ipc` port. Production wiring plugs in `window.electron`; tests plug in an in-memory fake.
- **Prefetch policy.** `prefetch.ts` is a separate file in the same folder. It uses the service like any other caller — it does not get privileged access.
- **HTMLAudioElement / playback.** `usePlayerMachine` owns playback; the service hands back a blob URL and is done.

### What's hidden behind the interface

Callers don't see: the priority queue, the slot mechanism, the retry/backoff schedule, the OpenAI request body shape, the bearer-vs-dev-bypass header logic, the cache directory structure, the `md5(cfiRange)` hashing, the dual-key write fanout, the size-based eviction throttle, the dedup listener registry, the listener-timeout cleanup, the `EventEmitter` internals.

## Dependencies

All four dependencies are **Ports & adapters** per the meta-spec's categorization (the service does not own them; production wires real adapters; tests wire fakes).

| Dep | What the service uses | Production adapter | Test adapter |
|---|---|---|---|
| `ipc` | `mkdir`, `exists`, `writeFile`, `readFile`, `copyFile`, `removeFile`, `getDirSize`, `getCacheFileStats`, `getAppDataPath` | `window.electron.{...}` (direct passthrough) | In-memory `makeIpc({ files: Map<string, Uint8Array> })` with sync semantics |
| `fetch` | `(url, init) => Promise<Response>` | Global `fetch` | `makeFetch({ audioBytes: Uint8Array, status?, delayMs? })` returning a Response-like with `.arrayBuffer()` |
| `getAuthToken` | `() => Promise<AuthHeader>` where `AuthHeader = { kind: 'bearer'; token: string } \| { kind: 'dev-bypass'; secret: string }` | Composes `getAuthToken()` from `modules/auth` + `window.electron.getDevBypassSecret()` at the wiring site | `makeAuthToken({ token: 'test-bearer' })` |
| `config` | `{ audioWorkerUrl: string; cacheMaxBytes: number; maxConcurrent: number }` | Read from `@/config.json` at the wiring site | Literal object in test |

The service is testable as plain code under vitest. No Electron runtime, no real `fetch`, no real disk.

## Public interface

### Types

```ts
// src/renderer/src/services/tts/types.ts

/** A request identifier derived from (bookId, cfiRange). Opaque to callers. */
export type TtsRequestId = string  // canonical form: `${bookId}-${cfiRange}`

export interface AudioRequest {
  bookId: string
  /** CFI range, or a `texthash:<md5>` synthetic key for prefetch. */
  cfiRange: string
  text: string
  /** Higher = sooner. Default 0. Active playback uses 1, prefetch uses 0. */
  priority?: number
}

export interface AudioReady {
  bookId: string
  cfiRange: string
  /** Blob URL (object URL) for an audio/mpeg blob. Caller is responsible for revoking. */
  audioPath: string
}

export interface TtsError {
  bookId: string
  cfiRange: string
  /** Human-readable error message. */
  error: string
}

export interface QueueStatus {
  /** Items waiting for a free concurrency slot. */
  pending: number
  /** True iff at least one request is currently being processed. */
  isProcessing: boolean
  /** Items currently in-flight (occupying a concurrency slot). */
  active: number
}

export type AuthHeader =
  | { kind: 'bearer'; token: string }
  | { kind: 'dev-bypass'; secret: string }

export interface TtsIpcChannels {
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
  writeFile(path: string, data: Uint8Array): Promise<void>
  readFile(path: string): Promise<ArrayBuffer>
  copyFile(src: string, dest: string): Promise<void>
  removeFile(path: string): Promise<void>
  getDirSize(path: string): Promise<number>
  getCacheFileStats(dir: string): Promise<Array<{ path: string; size: number; mtimeMs: number }>>
  getAppDataPath(): Promise<string>
}

export interface TtsConfig {
  audioWorkerUrl: string
  /** Hard cap on disk cache size. Default 500 MB. */
  cacheMaxBytes: number
  /** Max concurrent HTTP requests. Default 8. */
  maxConcurrent: number
}

export interface TtsServiceDeps {
  ipc: TtsIpcChannels
  fetch: (url: string, init: RequestInit) => Promise<Response>
  getAuthToken: () => Promise<AuthHeader>
  config: TtsConfig
}
```

### Service interface

```ts
// src/renderer/src/services/tts/index.ts

export interface TtsService {
  /**
   * Request audio for (bookId, cfiRange, text). Returns a blob URL for an
   * audio/mpeg blob. Cache-first: if the audio is already on disk, the
   * returned URL points at a fresh blob built from the cached bytes. Otherwise
   * the request is queued behind any equal-priority work; HTTP TTS is called;
   * the result is cached for next time.
   *
   * Concurrent calls with the same (bookId, cfiRange) deduplicate: one HTTP
   * call, one blob URL, distributed to every caller's promise.
   *
   * @throws Error  on auth failure, HTTP non-2xx after retries, empty
   *                response body, or 30s per-request HTTP timeout.
   */
  requestAudio(req: AudioRequest): Promise<string>

  /**
   * Cancel a specific in-flight request. Returns true if it was found and
   * cancelled; false if it had already completed or was never queued. The
   * cancelled promise rejects with `Error('Request cancelled')`.
   */
  cancelRequest(bookId: string, cfiRange: string): boolean

  /**
   * Cancel every in-flight or queued request for `bookId`. No-op if none.
   */
  cancelBookRequests(bookId: string): void

  /**
   * Wipe the disk cache for `bookId`. Best-effort: errors are logged and swallowed.
   */
  clearBookCache(bookId: string): Promise<void>

  /**
   * Snapshot of internal queue state. Intended for diagnostics (dev state
   * dump, debug UI). Not stable across versions.
   */
  getQueueStatus(): QueueStatus

  /**
   * Subscribe to "audio is ready" events. Returns an unsubscribe function.
   * The event fires *after* `requestAudio` resolves, for every successful
   * completion (including dedup'd ones).
   */
  onAudioReady(cb: (event: AudioReady) => void): () => void

  /**
   * Subscribe to "request failed" events. Returns an unsubscribe function.
   * Fires when a request rejects after retries are exhausted, or on auth /
   * cancellation failures.
   */
  onError(cb: (event: TtsError) => void): () => void
}

export function createTtsService(deps: TtsServiceDeps): TtsService
```

### Shape notes

- **Methods take a single `AudioRequest` object,** not 4 positional args. The current `(bookId, cfiRange, text, priority)` form is error-prone (two of the four params are strings).
- **No `EventEmitter` exposure.** `onAudioReady` / `onError` are the only subscription surface. Returns an unsubscribe function — the canonical idiom. Internally backed by a small `Emitter<T>` (or EventEmitter3 — implementation detail).
- **No `clearQueue()` method.** Current callers (`usePlayerMachine.cleanupAudio`) call it to clear pending work on player teardown, but the equivalent in the new shape is `cancelBookRequests(bookId)` — which is what the player actually wants. A nuclear "clear *everything*" is internal-only.
- **No `getBookCacheSize()` method.** Currently exposed but not called by anyone except the deleted test file. Drop it. If it's needed later it's a one-liner.
- **No `cancelRequest` by `requestId` string.** Callers always know `(bookId, cfiRange)`; computing the join is the service's job.

### Usage example — wiring site

```ts
// src/renderer/src/services/index.ts
import { createTtsService, type TtsService } from './tts'
import { getAuthToken as getBearer } from '@/modules/auth'
import config from '@/config.json'

let _tts: TtsService | null = null

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
        getAppDataPath: window.electron.getAppDataPath,
      },
      fetch: (url, init) => fetch(url, init),
      getAuthToken: async () => {
        const token = await getBearer()
        if (token) return { kind: 'bearer', token }
        const secret = await window.electron.getDevBypassSecret()
        if (secret) return { kind: 'dev-bypass', secret }
        throw new Error('Not authenticated — sign in to use text-to-speech')
      },
      config: {
        audioWorkerUrl: config.production.audio_worker_url,
        cacheMaxBytes: 500 * 1024 * 1024,
        maxConcurrent: 8,
      },
    })
  }
  return _tts
}
```

### Usage example — most common caller

```ts
// hooks/usePlayerMachine.ts (after migration)
import { getTtsService } from '@/services'

const tts = getTtsService()

// On state transition into 'loading':
const blobUrl = await tts.requestAudio({
  bookId: ctx.bookId,
  cfiRange: paragraph.index,
  text: paragraph.text,
  priority: 1,
})
await loadAndPlayAudio(blobUrl)

// On state transition out of any active state:
return () => {
  tts.cancelBookRequests(ctx.bookId)
}
```

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                  # wiring site (RAG + TTS so far)
├── rag/                      # Wave 1, service 1 — shipped earlier in Wave 1
│   └── ...
└── tts/
    ├── index.ts              # re-export: createTtsService, types, TtsService
    ├── types.ts              # all types in the "Types" section above
    ├── service.ts            # createTtsService — top-level wiring
    ├── cache.ts              # internal: makeCache(ipc, config)
    ├── queue.ts              # internal: makeQueue(deps) — priority queue + slot mgmt
    ├── transport.ts          # internal: makeTransport(fetch, getAuthToken, config) — HTTP
    ├── emitter.ts            # internal: tiny typed Emitter<T> wrapper
    ├── prefetch.ts           # exported helper: prefetchTTSForBooks(books, service)
    └── service.test.ts       # boundary tests
```

The internal modules (`cache.ts`, `queue.ts`, `transport.ts`, `emitter.ts`) are not re-exported from `index.ts`. They exist only as a refactoring convenience inside `service.ts` — Ousterhout's "deep module" principle says the *interface* is small, not the *implementation*.

`prefetch.ts` is exported (it's the replacement for the current `ttsPrefetch.ts`) but is a thin consumer, not part of the service surface.

## Migration

### Caller migration table

| File | Current | After |
|---|---|---|
| `src/renderer/src/hooks/usePlayerMachine.ts` | `import { ttsService } from '@/modules/ttsService'`; calls `ttsService.requestAudio(bookId, idx, text, p)` 4×, `ttsService.clearQueue()` 1× | `import { getTtsService } from '@/services'`; calls `getTtsService().requestAudio({ bookId, cfiRange: idx, text, priority: p })`; `getTtsService().cancelBookRequests(bookId)` replaces `clearQueue` |
| `src/renderer/src/modules/ipc_handel_functions.ts` (`requestTTSAudio`) | Wraps `ttsService.requestAudio` and re-throws after `captureError` | **Delete the file** or trim it. The Sentry capture moves *into* the service's error handler — every caller benefits, not just this wrapper. Callers of `requestTTSAudio` (only `ttsPrefetch`) migrate to `getTtsService()` |
| `src/renderer/src/modules/ttsPrefetch.ts` | Top-level module importing `requestTTSAudio` | **Move** to `src/renderer/src/services/tts/prefetch.ts`. Imports `getTtsService` from `@/services`. Same public function `prefetchTTSForBooks(books)` — the one external caller (`FileComponent.tsx`) only updates the import path |
| `src/renderer/src/components/FileComponent.tsx` | `import { prefetchTTSForBooks } from '@/modules/ttsPrefetch'` | `import { prefetchTTSForBooks } from '@/services/tts/prefetch'` |
| `src/renderer/src/utils/stateDump.ts` | `import { ttsQueue } from '../modules/ttsQueue'` + `import { ttsService } from '../modules/ttsService'` (only uses `ttsQueue.getQueueStatus()`) | `import { getTtsService } from '@/services'`; calls `getTtsService().getQueueStatus()`. Drops the second import entirely |

Total: 5 caller files touched. Two of them are one-line import changes.

### Files to delete

| File | Reason |
|---|---|
| `src/renderer/src/modules/ttsService.ts` | Absorbed into `services/tts/service.ts` |
| `src/renderer/src/modules/ttsQueue.ts` | Absorbed into `services/tts/queue.ts` (internal) |
| `src/renderer/src/modules/ttsCache.ts` | Absorbed into `services/tts/cache.ts` (internal) |
| `src/renderer/src/modules/ttsPrefetch.ts` | Moved to `services/tts/prefetch.ts` |
| `src/renderer/src/modules/ipc_handel_functions.ts` (`requestTTSAudio` export) | Wrapper layer removed; if file has other exports, only this one goes |
| `src/renderer/src/modules/ipc_handles.ts` (`TTS_EVENTS`, `TTSQueueEvents` enums) | Internal event names no longer cross module boundaries |
| `src/renderer/src/modules/__tests__/ttsService.test.ts` (or wherever it lives — co-located today) | Tests shallow modules; replaced by `services/tts/service.test.ts` |
| `src/renderer/src/modules/__tests__/ttsQueue.test.ts` | Same |
| `src/renderer/src/modules/__tests__/ttsCache.test.ts` | Same |

Per the meta-spec's *no shims* rule: no compatibility re-exports. One PR, one source of truth.

### PR strategy

Single PR, structured commits per the meta-spec's TDD discipline:

1. **Scaffold** — create `services/tts/` with `types.ts` (full) and stubs for `service.ts`, `cache.ts`, `queue.ts`, `transport.ts`, `emitter.ts`, `prefetch.ts`. Set up `service.test.ts` with `makeIpc()`, `makeFetch()`, `makeAuthToken()` helpers.
2. **Cache happy path + test.** Red. Implement `cache.ts` with `mkdir` / `exists` / `writeFile` / `readFile`. Green.
3. **Cache fallback (CFI miss → text-hash hit) + test.** Red. Implement dual-key write fanout. Green.
4. **Cache eviction throttle + test.** Red. Implement size-check + LRU eviction. Green.
5. **Transport happy path + test.** Red. Implement HTTP call, bearer header path, body parsing. Green.
6. **Transport dev-bypass path + test.** Red. Wire `getAuthToken` switching. Green.
7. **Transport HTTP error + test.** Red. Implement error wrapping. Green.
8. **Queue priority + test.** Red. Implement priority-ordered slot fill. Green.
9. **Queue dedup + test.** Red. Implement pending-by-id map. Green.
10. **Queue overflow trim + test.** Red. Implement `MAX_QUEUE_SIZE` rebuild. Green.
11. **Queue retry-with-backoff + test.** Red. Implement retry classifier + exponential delay. Green.
12. **Service-level cache-first flow + test.** Red. Wire cache before queue. Green.
13. **Service-level cancellation + test.** Red. Implement `cancelRequest` / `cancelBookRequests`. Green.
14. **Subscription API + test.** Red. Implement `onAudioReady` / `onError` with unsubscribe. Green.
15. **Wiring + caller migrations** (no new tests — composition).
16. **Delete old files + tests** in one commit.
17. **Final verification.** `tsc` / `eslint` / `vitest` clean.

Each step is one commit. Steps 2-14 are red-green pairs; the rest are mechanical.

### Expected diff

- **Added:** ~900 lines (service + tests + types + prefetch + wiring).
- **Removed:** ~1100 lines (old quartet + their 3 test files + thin wrapper).
- **Net:** slightly negative. The deep-module discipline produces less code than the spread-thin alternative.

## Test strategy

### Placement

All tests at the boundary: one file, `src/renderer/src/services/tts/service.test.ts`. Tests use `createTtsService({ ipc, fetch, getAuthToken, config })` with fakes — no global mocks, no module reset between tests.

### Test helpers (planned shape)

```ts
function makeIpc(initial?: { files?: Record<string, Uint8Array> }): {
  ipc: TtsIpcChannels
  files: Map<string, Uint8Array>
  callLog: Array<{ method: keyof TtsIpcChannels; args: unknown[] }>
}

function makeFetch(opts: {
  audioBytes?: Uint8Array
  status?: number
  errorBody?: string
  delayMs?: number
  failNTimes?: number
}): {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  callCount: () => number
}

function makeAuthToken(opts: { token?: string; secret?: string; rejectWith?: Error }):
  () => Promise<AuthHeader>
```

The fakes are ~100 lines total — trivial. Crucially: no `vi.mock`, no `vi.resetModules` between tests. The service is constructed fresh per test, no shared state.

### Boundary test scenarios (committed)

Minimum 12 tests; tracks the major behaviors the current 3 test files cover plus the new dedup-across-cancellation semantics.

1. **`requestAudio` cache miss → HTTP → blob URL.** Setup: empty `ipc`, `fetch` returns 8-byte audio. Assert: result starts with `blob:`, `fetch` called once with correct URL + bearer header, `ipc.writeFile` called with cache path containing `.mp3`.
2. **`requestAudio` cache hit → no HTTP.** Setup: `ipc.files` pre-populated at the canonical cache path. Assert: `fetch` *never* called, result is a blob URL built from cached bytes.
3. **`requestAudio` cache hit via text-hash fallback.** Setup: `ipc.files` populated only at the `texthash:<md5>` path. Assert: lookup returns the cached blob; no HTTP call.
4. **`requestAudio` write-through saves under both CFI and text-hash keys.** Setup: cache miss, text provided. Assert: `ipc.writeFile` called for CFI path; `ipc.copyFile` called for text-hash path.
5. **Concurrent `requestAudio` for same key dedups.** Setup: fire 3 `requestAudio` calls in parallel for the same (book, cfi). Assert: all three resolve to the same URL, `fetch` called exactly once.
6. **`requestAudio` retries on retryable HTTP failure.** Setup: `fetch` fails with 503 twice then succeeds. Assert: result is blob URL, `fetch` called 3×, exponential backoff observed.
7. **`requestAudio` rejects on non-retryable HTTP failure.** Setup: `fetch` returns 401 with body `"unauthorized"`. Assert: promise rejects with Error containing `401`, `fetch` called once (no retries on non-retryable status).
8. **`requestAudio` propagates auth failure.** Setup: `getAuthToken` rejects with `Error('no session')`. Assert: promise rejects with auth error; `fetch` *never* called.
9. **`requestAudio` uses dev-bypass header when auth port returns `dev-bypass` kind.** Setup: `getAuthToken` returns `{ kind: 'dev-bypass', secret: 's3cret' }`. Assert: `fetch` called with `X-Dev-Bypass: s3cret` header, no `Authorization` header.
10. **`cancelRequest` rejects in-flight promise.** Setup: fire `requestAudio` with `fetch` that never resolves. Call `cancelRequest`. Assert: the original promise rejects with `Error('Request cancelled')`; `cancelRequest` returns `true`.
11. **`cancelBookRequests` rejects all promises for a book.** Setup: fire 3 requests for book `A` and 1 for book `B`. Call `cancelBookRequests('A')`. Assert: A's three reject, B's resolves normally.
12. **`onAudioReady` subscriber fires after `requestAudio` resolves; unsubscribe stops further events.** Assert: handler called with `{bookId, cfiRange, audioPath}`. After `unsubscribe()`, second request does not invoke handler.

### Tests we explicitly do NOT add

- Performance / throughput assertions (slot timing, queue ordering under load).
- The 30s listener-timeout cleanup (it's a defense-in-depth leak guard, not a public behavior).
- Cache eviction at the 500 MB threshold — that's tested implicitly via the cache module's seam but not a public-interface contract.
- The state-dump integration in `stateDump.ts` (covered by the existing `stateDump` tests, which keep working unchanged after the one-line import swap).

### What inherited tests get deleted

All three of `ttsService.test.ts` / `ttsQueue.test.ts` / `ttsCache.test.ts`. Per the meta-spec: they describe shallow-module implementation, not service behavior. The replacement is the 12-test file above, which covers the same behavior at a higher level with cleaner fakes.

## Open questions

These are the open design questions the implementation plan should resolve. They are flagged but **not** decided in this spec.

1. **Should `prefetch.ts` live inside the service module or stay external?** *Lean: keep co-located at `services/tts/prefetch.ts` but export it as a *helper*, not as part of the `TtsService` interface.* Rationale: it's a higher-level orchestration over the service (iterates a book list, looks up paragraphs, picks a target page) — it's not part of the service's atomic contract. Co-locating keeps the import path tidy; keeping it external to the interface keeps the service surface small. The spec assumes this lean; the plan can revisit.

2. **Should the `audioWorkerUrl` baseUrl come from the existing `config.production` import, or be injected as `config` port?** *Lean: inject for test substitutability.* Rationale: the service should never know about `config.json`. The wiring site at `services/index.ts` is the one place that imports `config.json` and feeds it in. The spec assumes injection. The cost is a 3-line config object at the wiring site; the win is that tests don't need to mock the config module.

3. **Is the dev-bypass header logic worth keeping at the service layer or only in the `getAuthToken` port?** *Lean: only in the port — service doesn't know about dev bypass.* Rationale: dev-bypass is a *credential mechanism*, not a TTS concern. The current `ttsQueue.generateAudio` mixes credential acquisition into the HTTP call; the cleaner split is `getAuthToken()` returns a discriminated union, transport branches on the discriminator to pick the header name. This pushes the Clerk-vs-bypass logic up into the wiring site, where it belongs alongside every other auth-aware caller.

## Stage 2 outlook

Stage 2 is explicit Effect-TS adoption *inside* a service, after Stage 1 ships. The meta-spec sets a rubric: Effect goes into a service only if it scores positively on ≥2 of 5 axes.

### Scoring TTS against the rubric

| Axis | Score | Why |
|---|---|---|
| **Concurrency** | YES | Slot-based concurrency (`MAX_CONCURRENCY=8`), priority queue, in-flight dedup — `Effect.Semaphore` + `Queue` is a direct fit. |
| **Retry / scheduling** | YES | Exponential backoff with retryable-error classification — `Schedule.exponential` + `Schedule.whileInput` are exactly this. |
| **Resource lifecycle** | YES | Blob URLs need revoking, cancellation needs to propagate to in-flight HTTP, listener cleanup on unsubscribe — `acquireRelease` + `Scope` handle this cleanly. |
| **Typed error channels** | PARTIAL | Three error categories today (auth failure, HTTP error, cancellation) but the service has no caller that exhaustively switches on them. Effect would *enable* this but no caller demands it. |
| **Composed async pipeline** | YES | cache-check → queue → auth → fetch → parse → cache-write → resolve is a long sequential pipeline with branching. `Effect.gen` is more readable than nested try/catch. |

**Score:** 4 of 5 axes (strong yes), with the 5th partial. TTS is the strongest Stage 2 candidate in the catalog — likely the *first* Stage 2 retrofit.

### Stage 2 sketch

The public interface stays plain TS (`Promise<string>` from `requestAudio`, callback-based `on*`). Internally:

- **`queue.ts` → `Effect.Queue`.** The `PriorityQueue` + slot-fill logic becomes `Queue.bounded` + `Semaphore.make(maxConcurrent)`. The whole `fillSlots` loop disappears.
- **`transport.ts` → `Effect.gen` with `Schedule`.** Retry policy becomes one `Schedule` value. The "is this a retryable error" classifier becomes a typed error subclass + `Schedule.whileInputEffect` filter.
- **Cancellation → `Scope` / `Fiber.interrupt`.** Each request runs in its own fiber; `cancelRequest` calls `Fiber.interrupt`. Resource cleanup (revoking pending blob URLs, removing listeners) is automatic.
- **`requestAudio` boundary.** Wrapper at the top: `Effect.runPromise(serviceEffect(...))`. Callers don't change.

The interface contract from Stage 1 is preserved exactly. The internals shrink. The retry / dedup / cancellation logic that's currently hand-rolled across two files becomes a 30-line Effect program.

### Stage 2 trigger

Per the meta-spec, Stage 2 starts only after **all six Stage 1 services have shipped**. This spec commits no Stage 2 work. The sketch above exists so the team can validate the public interface won't need to break when Stage 2 lands.

### Stopping rule

Per the meta-spec: if Stage 2 ergonomics are painful when TTS is retrofitted, Effect is removed from TTS, Stage 2 stops, and the rest of the services stay plain TS. The Stage 1 service from this spec is *unaffected* by that outcome — its public interface is the durable artifact.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/tts/index.ts` is the single public-facing module exporting `createTtsService`, `TtsService`, and types.
2. `src/renderer/src/services/index.ts` exports `getTtsService()` lazy singleton.
3. All 5 callers (`usePlayerMachine`, `FileComponent`, `stateDump`, `ttsPrefetch` consumers, the deleted `requestTTSAudio` callers) use `getTtsService()` directly or import `prefetchTTSForBooks` from the new path.
4. The 4 old module files plus 3 old test files are **deleted**, not kept as shims.
5. All 12 boundary tests pass.
6. `tsc`, `eslint`, `vitest` clean across the app.
