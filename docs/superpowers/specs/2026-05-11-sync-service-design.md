# Sync service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 1, service #4 of 6. Stage 1 only (plain TypeScript). `apps/rishi-electron` renderer-side service that consolidates `sync-triggers` + `sync-adapter` into one deep module composing around the shared `@rishi/shared/sync-engine`.

## Goal

Collapse the current renderer-side sync surface (`sync-triggers.ts` module-level singleton + free function exports + `DesktopSyncAdapter` class) into one cohesive renderer-side service exposed through a small, typed interface. Hide engine construction, the IPC adapter, the debounced write trigger, the online/offline / focus / interval lifecycle wiring, status state, and the in-flight guard behind a ~4-method facade. Callers stop importing two modules and a free function; they call `getSyncService().triggerWrite()` (or `start` / `stop` / `getStatus` / `onStatusChange`).

## Background

Sync today is split across two renderer-side modules plus several call sites:

- **`modules/sync-triggers.ts`** — a 200-line module that owns a module-scoped `SyncEngine | null` singleton, four module-scoped event handler refs (`focusHandler`, `onlineHandler`, `offlineHandler`, `intervalId`), a `Set<SyncStatusListener>` registry, the `syncStatus` + `lastSyncAt` state, the `apiFetch` function (bearer + dev-bypass + 30s timeout + 401-retry), the public `triggerSync()` / `initDesktopSync()` / `destroyDesktopSync()` / `triggerSyncOnWrite()` / `onSyncStatusChange()` / `getSyncStatus()` exports, a module-scoped `writeTimeout` for the debounce, and direct reads of `navigator.onLine`.
- **`modules/sync-adapter.ts`** — a class implementing `@rishi/shared/sync-adapter`'s `SyncDbAdapter` by wrapping 14 `window.electron.sync*` IPC methods. Pure marshalling: input → IPC call → output normalization.
- **Six call sites** import from these two files: `__root.tsx` (start/stop lifecycle), `SyncStatusIndicator.tsx` (subscribe), `NoteEditor.tsx` / `HighlightsPanel.tsx` / `EpubView.tsx` (write triggers), `useChat.ts` (write trigger).

Symptoms that motivated the meta-spec:

- **Module-scoped mutable state is the *only* state model.** Eight `let` bindings at module scope (`engine`, `syncStatus`, `lastSyncAt`, `intervalId`, `focusHandler`, `onlineHandler`, `offlineHandler`, `writeTimeout`) plus a `Set` of listeners. Every function in the file pokes one or more of them. There is no constructor, no factory, no test seam — `vi.resetModules()` is the only way to get a clean slate. The existing `sync-triggers.test.ts` is two trivial tests (status listener fires; init+destroy doesn't throw) precisely because nothing else is reachable without rebuilding module state.
- **`navigator.onLine` is read inline.** Three places: the offline handler, the interval guard, the catch-block status classification. The Connectivity refactor landed a `modules/connectivity.ts` with `isOnline()` + an actor subscription, but Sync never consumes it. Two sources of truth for "are we online."
- **Auth fetch wrapper is tangled in.** `apiFetch` lives inside `sync-triggers.ts` and pulls in `getAuthToken` + `window.electron.getDevBypassSecret` + the worker URL constant directly. The engine constructor receives it as a closure, but the wrapper is not externally substitutable — tests can't inject a fake `apiFetch`.
- **The adapter is a class.** `class DesktopSyncAdapter implements SyncDbAdapter` — instance state is zero, every method is a one-line `await window.electron.sync*(...)`. There's no reason it's a class beyond ergonomics; the class boundary means every IPC method is reached by `new DesktopSyncAdapter()` somewhere, and tests have to construct one to assert per-method behavior. The existing `sync-adapter.test.ts` is 14 trivial tests, one per method, asserting "calls `window.electron.X` with these args."
- **The debounce timer is a module-scoped `let`.** `triggerSyncOnWrite` resets a module-scoped `writeTimeout`. There is no way to flush it, cancel it, or substitute its `setTimeout`. The existing tests never exercise it.
- **Engine status events are not surfaced.** `engine.sync()` is the only engine method called; any progress events / per-record telemetry from the engine's internals are inaccessible. Today's status surface (`'not-synced' | 'syncing' | 'synced' | 'error' | 'offline'`) is derived entirely in the wrapper.
- **No single owner of "schedule a write; we'll get it to the server eventually."** Every caller imports a free function (`triggerSyncOnWrite`) from a module, with no way to inject a fake.

There is no single owner of "the renderer-side sync lifecycle." Every layer pokes part of it.

This refactor introduces a single renderer-side Sync service that wraps engine construction + IPC adapter + auth-aware fetch + debounce + online/focus/interval wiring + status emission, exposes a small typed interface plus a subscription API, and replaces every caller's import. The shared `@rishi/shared/sync-engine` stays external — the service composes around it.

## Non-goals

- Changing the sync protocol, server endpoints, push/pull semantics, conflict resolution policy, or LWW guards. Behavior preserved.
- Replacing the shared `@rishi/shared/sync-engine` package. It stays as-is and is consumed via an injected factory port.
- Touching the main-process IPC handlers in `src/main/ipc/sync.ts`. Their surface stays as-is; the service consumes them through an injected `ipc` port.
- Adding new features (per-table sync status, sync progress percentage, manual conflict resolution UI, batch size tuning). Scope guard per meta-spec.
- Migrating to Effect-TS. Stage 1 is plain TypeScript. Effect is a Stage 2 candidate (see "Stage 2 outlook" below).
- Replacing the existing `connectivityActor` / `useIsOnline` surface. The service consumes a connectivity *port* matching its shape; the production wiring imports `modules/connectivity.ts` directly. If/when the Connectivity service refactor lands its `getConnectivityService()` wiring, the Sync wiring site swaps one import — no internal service change.

## Decision summary

| Question | Decision |
|---|---|
| Service scope | Engine lifecycle + IPC adapter + debounced write trigger + status emission + online/focus/interval wiring + auth-aware fetch. |
| Boundary | One module: `services/sync/`. Single factory `createSyncService(deps)`. |
| Public interface size | 4 methods + 1 subscribe API. No free functions, no class export, no `EventEmitter`. |
| Return shape | `start()` / `stop()` / `triggerWrite()` return `void`. `getStatus()` returns a snapshot record. `onStatusChange` returns an unsubscribe function. The engine's `sync()` call stays internal — no public `triggerSync()` method (it's a side effect of `triggerWrite()`, online recovery, focus, interval, and `start()`). |
| Status type | Same discriminated string union as today: `'not-synced' \| 'syncing' \| 'synced' \| 'error' \| 'offline'`. Paired with `lastSyncAt: number \| null`. |
| Engine ownership | The shared `createSyncEngine` is injected as a `engineFactory` port. Production wiring passes `createSyncEngine` from `@rishi/shared/sync-engine`. Tests pass a stub returning a fake `{ sync: vi.fn() }`. |
| IPC | Injected `ipc` port containing the 14 `window.electron.sync*` methods the adapter uses. The service builds the `SyncDbAdapter` internally from this port. The class `DesktopSyncAdapter` is **deleted**; the adapter becomes an internal factory function. |
| Auth | Pushed out via an injected `getAuthToken: () => Promise<string \| null>` port + a `getDevBypassSecret: () => Promise<string \| null>` port. Service knows nothing about Clerk vs dev-bypass — composition lives at the wiring site (same pattern TTS uses). |
| HTTP transport | Injected `fetch` port (`(url, init) => Promise<Response>`). The auth-aware wrapper is constructed *inside* the service using `fetch` + `getAuthToken` + `getDevBypassSecret` + `config.workerUrl`. |
| Connectivity | Injected `connectivity` port: `{ isOnline(): boolean; subscribe(listener: (online: boolean) => void): () => void }`. Matches the just-landed `modules/connectivity.ts` (with `subscribe` added — see "Connectivity port" below) and the planned `getConnectivityService()` shape. Service no longer reads `navigator.onLine` directly. |
| Config | Injected `config` port — `{ workerUrl: string; intervalMs: number; debounceMs: number; requestTimeoutMs: number }`. Defaults at the wiring site. |
| Clock | Injected `clock` port: `{ now(): number; setTimeout, clearTimeout, setInterval, clearInterval }`. Production wiring passes the globals. Tests pass a fake clock for deterministic debounce / interval behavior. |
| Window events | Injected `windowEvents` port: `{ addEventListener, removeEventListener }`. Production wiring passes `window`. Tests pass an in-memory event bus. (The `'focus'` event and `'sync-auth-expired'` custom event both flow through this port.) |
| Error model | `Promise` rejections inside engine internals are caught and routed to status `'error'` (or `'offline'` if connectivity is down). No typed error channel exposed in Stage 1. The `AUTH_EXPIRED` engine signal dispatches a `'sync-auth-expired'` custom event via `windowEvents` (unchanged behavior). |
| `start()` idempotency | Yes. Calling `start()` on an already-started service is a no-op. Mirrors today's `initDesktopSync` guard. |
| `stop()` idempotency | Yes. Calling `stop()` on an already-stopped (or never-started) service is a no-op. |
| Events | Small `createEmitter<T>()` — `service.onStatusChange(cb)` returns `() => void` unsubscribe handle. Same primitive as TTS uses (re-imported from `services/tts/emitter.ts`, or duplicated for module independence — see open questions). |
| Wiring site | `src/renderer/src/services/index.ts` (same wiring site introduced by RAG / TTS). Lazy singleton via `getSyncService()`. |
| Test placement | One file: `src/renderer/src/services/sync/service.test.ts`. Existing 2 test files deleted as redundant. |
| Effect adoption (Stage 2) | Plausible. Predicted 3-4 of 5 axes (retry/scheduling, online-gated concurrency, composed pipeline, possibly typed errors). Internal-only adoption; public interface stays plain TS. |

## Boundary

### What the service owns

- Lazy construction of `SyncEngine` via the injected factory + the internally-built `SyncDbAdapter`.
- The auth-aware `apiFetch` wrapper passed to the engine (bearer header path, dev-bypass header fallback, 30s timeout, 401-retry-with-fresh-token).
- The triggering policy: initial sync on `start()`, periodic sync every `config.intervalMs`, sync on `'focus'` event, sync on online-transition recovery, debounced sync on `triggerWrite()`.
- The status state machine — `'not-synced' → 'syncing' → 'synced' | 'error' | 'offline'` — and the listener fanout.
- The in-flight guard — concurrent `triggerWrite()` / interval / focus calls coalesce; only one engine sync runs at a time.
- The debounce — `triggerWrite()` calls coalesce within `config.debounceMs`.
- Lifecycle teardown — every listener registered in `start()` is unregistered in `stop()`.
- Dispatching the `'sync-auth-expired'` custom event on `AUTH_EXPIRED` engine signal.

### What stays outside

- **The shared `@rishi/shared/sync-engine`.** Owned by the shared package. The service consumes it via an injected factory.
- **The shared `@rishi/shared/sync-adapter` interface (`SyncDbAdapter`).** The service implements it internally but the *type* is owned by the shared package.
- **The main-process IPC handlers** in `src/main/ipc/sync.ts`. Stay as-is; the renderer service consumes them through the `ipc` port.
- **Authentication source.** `getAuthToken` + `getDevBypassSecret` ports are injected; the Clerk + dev-bypass logic lives at the wiring site, alongside every other auth-aware caller.
- **The worker URL / interval / debounce / timeout knobs.** Injected via `config`.
- **The `window.electron.*` surface.** Injected via `ipc` port. Production wiring plugs in `window.electron`; tests plug in an in-memory fake.
- **The `connectivityActor` / `useIsOnline` machinery.** The service consumes a connectivity *port*; today's wiring imports `modules/connectivity.ts` directly. The xstate machine is not consumed by the service.
- **The Sync status UI rendering.** `SyncStatusIndicator` keeps its layout; only the import path and the subscribe signature change.

### What's hidden behind the interface

Callers don't see: the engine type, the adapter type, the IPC method names, the auth header logic, the 401-retry, the 30s timeout, the `'focus'` listener, the `'online'` / `'offline'` listeners, the interval ID, the debounce timer, the in-flight guard, the `Set<listener>` registry, the `'sync-auth-expired'` dispatch.

## Dependencies

All seven dependencies are categorized per the meta-spec.

| Dep | Category | What the service uses | Production adapter | Test adapter |
|---|---|---|---|---|
| `ipc` | Remote-but-owned (port + adapter) | 14 `window.electron.sync*` methods | `{ syncGetDirtyBooks: window.electron.syncGetDirtyBooks, ... }` (direct passthrough) | `makeIpc({ books, highlights, conversations, messages, lastVersion })` — in-memory stores |
| `engineFactory` | In-process | `(config) => SyncEngine` | `createSyncEngine` from `@rishi/shared/sync-engine` | `makeEngine({ syncImpl })` — returns `{ sync: vi.fn(syncImpl) }` |
| `fetch` | External | `(url, init) => Promise<Response>` | Global `fetch` | `makeFetch({ status?, body?, delayMs? })` |
| `getAuthToken` | In-process | `() => Promise<string \| null>` | `getAuthToken` from `@/modules/auth` | `makeAuthToken({ token: 'test-bearer' })` |
| `getDevBypassSecret` | In-process | `() => Promise<string \| null>` | `window.electron.getDevBypassSecret` | `() => Promise<null>` by default |
| `connectivity` | In-process / local-substitutable | `{ isOnline(): boolean; subscribe(cb): () => void }` | Built from `modules/connectivity.ts` (see "Connectivity port" below) | `makeConnectivity({ initialOnline })` with `.setOnline(boolean)` test helper |
| `clock` | In-process | `{ now, setTimeout, clearTimeout, setInterval, clearInterval }` | The globals | `makeClock()` — virtual time, advance via `.tick(ms)` |
| `windowEvents` | External | `{ addEventListener(type, listener), removeEventListener(type, listener), dispatchEvent(event) }` | `window` (only the three method bindings) | `makeWindowEvents()` — in-memory event bus with `.fire(type, event)` |
| `config` | In-process | `{ workerUrl, intervalMs, debounceMs, requestTimeoutMs }` | Literal at wiring site | Literal in tests |

The service is testable as plain code under vitest. No Electron runtime, no real `fetch`, no real DOM, no real clock.

### Connectivity port

The just-landed `modules/connectivity.ts` exposes `connectivityActor` (xstate) + `isOnline()`. The service needs *both* a synchronous read and a subscription. The connectivity port shape is:

```ts
export interface ConnectivityPort {
  isOnline(): boolean
  /** Listener fires on transitions. Returns an unsubscribe function. */
  subscribe(listener: (online: boolean) => void): () => void
}
```

The wiring site builds this from `modules/connectivity.ts`:

```ts
import { connectivityActor, isOnline } from '@/modules/connectivity'

const connectivity: ConnectivityPort = {
  isOnline,
  subscribe: (listener) => {
    let last = isOnline()
    const sub = connectivityActor.subscribe(() => {
      const next = isOnline()
      if (next !== last) {
        last = next
        listener(next)
      }
    })
    return () => sub.unsubscribe()
  }
}
```

When the Connectivity service refactor lands its `getConnectivityService()`, the Sync wiring site changes to `const connectivity = getConnectivityService()` and the adapter above is deleted. The service-internal port shape is identical to the Connectivity service's public interface, so no service-internal change is needed.

## Public interface

### Types

```ts
// src/renderer/src/services/sync/types.ts

export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline'

export interface SyncStatusSnapshot {
  status: SyncStatus
  /** Epoch ms of the last successful sync, or null if none has succeeded. */
  lastSyncAt: number | null
}

export type SyncStatusListener = (snapshot: SyncStatusSnapshot) => void

export interface SyncIpcChannels {
  // Push: read dirty records
  syncGetDirtyBooks(): Promise<unknown[]>
  syncGetDirtyHighlights(): Promise<unknown[]>
  syncGetDirtyConversations(): Promise<unknown[]>
  syncGetDirtyMessages(): Promise<unknown[]>
  syncGetLastVersion(): Promise<number>

  // Push: mark pushed records clean
  syncMarkBooksClean(ids: string[], syncVersion: number): Promise<void>
  syncMarkHighlightsClean(ids: string[], syncVersion: number): Promise<void>
  syncMarkConversationsClean(ids: string[], syncVersion: number): Promise<void>
  syncMarkMessagesClean(ids: string[], syncVersion: number): Promise<void>

  // Push: conflict handlers
  syncApplyBookConflict(conflict: Record<string, unknown>, syncVersion: number): Promise<void>
  syncApplyHighlightConflict(conflict: Record<string, unknown>, syncVersion: number): Promise<void>
  syncApplyConversationConflict(conflict: Record<string, unknown>, syncVersion: number): Promise<void>

  // Pull: upsert remote records
  syncUpsertBook(remote: Record<string, unknown>): Promise<void>
  syncUpsertHighlight(remote: Record<string, unknown>): Promise<void>
  syncUpsertConversation(remote: Record<string, unknown>): Promise<void>
  syncInsertMessage(remote: Record<string, unknown>): Promise<void>
  syncUpdateLastVersion(version: number): Promise<void>
}

export interface SyncConfig {
  /** Sync server base URL. e.g. `https://api.fidexa.org` */
  workerUrl: string
  /** Periodic sync interval. Default 5 * 60 * 1000 (5 minutes). */
  intervalMs: number
  /** Debounce window for `triggerWrite()`. Default 2000. */
  debounceMs: number
  /** Per-request HTTP timeout for sync push/pull. Default 30000. */
  requestTimeoutMs: number
}

export interface ConnectivityPort {
  isOnline(): boolean
  subscribe(listener: (online: boolean) => void): () => void
}

export interface ClockPort {
  now(): number
  setTimeout(fn: () => void, ms: number): ReturnType<typeof setTimeout>
  clearTimeout(handle: ReturnType<typeof setTimeout>): void
  setInterval(fn: () => void, ms: number): ReturnType<typeof setInterval>
  clearInterval(handle: ReturnType<typeof setInterval>): void
}

export interface WindowEventsPort {
  addEventListener(type: string, listener: EventListener): void
  removeEventListener(type: string, listener: EventListener): void
  dispatchEvent(event: Event): void
}

export interface EngineLike {
  sync(): Promise<void>
}

export interface EngineFactoryConfig {
  adapter: import('@rishi/shared/sync-adapter').SyncDbAdapter
  apiFetch: (path: string, init?: RequestInit) => Promise<Response>
}

export type EngineFactory = (config: EngineFactoryConfig) => EngineLike

export interface SyncServiceDeps {
  ipc: SyncIpcChannels
  engineFactory: EngineFactory
  fetch: (url: string, init?: RequestInit) => Promise<Response>
  getAuthToken: () => Promise<string | null>
  getDevBypassSecret: () => Promise<string | null>
  connectivity: ConnectivityPort
  clock: ClockPort
  windowEvents: WindowEventsPort
  config: SyncConfig
}
```

### Service interface

```ts
// src/renderer/src/services/sync/index.ts

export interface SyncService {
  /**
   * Start the sync lifecycle: construct the engine if not yet built, register
   * focus / online / offline / interval listeners, kick an initial sync.
   * Idempotent — calling start() on an already-started service is a no-op.
   */
  start(): void

  /**
   * Stop the sync lifecycle: unregister every listener, clear the interval and
   * any pending debounce, drop the engine reference. After stop(), subsequent
   * triggerWrite() calls are no-ops until start() is called again. Idempotent.
   */
  stop(): void

  /**
   * Schedule a sync after a debounce window (default 2000ms). Repeated calls
   * within the debounce window coalesce into a single sync. No-op if the
   * service has not been started, or if the connectivity port reports offline.
   */
  triggerWrite(): void

  /**
   * Snapshot of the current sync status. Safe to call before start() —
   * returns `{ status: 'not-synced', lastSyncAt: null }` in that case.
   */
  getStatus(): SyncStatusSnapshot

  /**
   * Subscribe to status-change events. The listener is invoked **immediately
   * on subscribe** with the current snapshot (matching today's behavior) and
   * thereafter on every transition. Returns an unsubscribe function.
   */
  onStatusChange(listener: SyncStatusListener): () => void
}

export function createSyncService(deps: SyncServiceDeps): SyncService
```

### Shape notes

- **No `triggerSync()` public method.** Today's free function is internal to the trigger policy. Callers that want "sync now" call `triggerWrite()`, which fires after the debounce. There is no production caller of `triggerSync()` outside `sync-triggers.ts` itself.
- **No `getEngine()` or `getAdapter()` escape hatch.** The internal types are not part of the public surface.
- **`onStatusChange` invokes the listener immediately** — preserves the current `sync-triggers.ts` behavior, which `SyncStatusIndicator` depends on (it reads the initial status without a separate `getStatus()` call). This *differs* from the Connectivity service spec's "only on transitions" semantics, deliberately — Sync's status is more like a state snapshot, where "what's the current state?" is the most common need.
- **`start()` does not return a Promise.** The initial sync is fire-and-forget; status updates flow through `onStatusChange`. Mirrors today's `initDesktopSync` semantics — no caller awaits it.
- **`stop()` is synchronous.** Cancels timers, removes listeners, drops the engine. Any in-flight `engine.sync()` continues to completion but its status update is suppressed (no-op against the dropped engine).

### Usage example — wiring site

```ts
// src/renderer/src/services/index.ts (additive — appended after getTtsService)
import { createSyncService, type SyncService, type ConnectivityPort } from './sync'
import { createSyncEngine } from '@rishi/shared/sync-engine'
import { connectivityActor, isOnline } from '@/modules/connectivity'
import { getAuthToken } from '@/modules/auth'

let _sync: SyncService | null = null

export function getSyncService(): SyncService {
  if (!_sync) {
    const connectivity: ConnectivityPort = {
      isOnline,
      subscribe: (listener) => {
        let last = isOnline()
        const sub = connectivityActor.subscribe(() => {
          const next = isOnline()
          if (next !== last) {
            last = next
            listener(next)
          }
        })
        return () => sub.unsubscribe()
      }
    }

    _sync = createSyncService({
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
      connectivity,
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
  }
  return _sync
}
```

### Usage example — most common callers

```ts
// routes/__root.tsx (lifecycle)
import { getSyncService } from '@/services'

useEffect(() => {
  const sync = getSyncService()
  sync.start()
  return () => sync.stop()
}, [])
```

```ts
// components/highlights/NoteEditor.tsx (write trigger)
import { getSyncService } from '@/services'

const handleSave = () => {
  saveHighlight(...)
  getSyncService().triggerWrite()
}
```

```ts
// components/SyncStatusIndicator.tsx (subscribe)
import { useEffect, useState } from 'react'
import { getSyncService, type SyncStatusSnapshot } from '@/services'

export function SyncStatusIndicator() {
  const [snapshot, setSnapshot] = useState<SyncStatusSnapshot>(
    () => getSyncService().getStatus()
  )
  useEffect(() => getSyncService().onStatusChange(setSnapshot), [])

  if (snapshot.status === 'synced' || snapshot.status === 'not-synced') return null
  // ... existing label rendering
}
```

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                  # wiring site — adds getSyncService() alongside RAG / TTS
├── rag/
├── tts/
└── sync/
    ├── index.ts              # re-export: createSyncService, types, SyncService
    ├── types.ts              # all types in the "Types" section above
    ├── service.ts            # createSyncService — top-level wiring
    ├── adapter.ts            # internal: makeAdapter(ipc) — builds SyncDbAdapter from ipc port
    ├── apiFetch.ts           # internal: makeApiFetch({ fetch, getAuthToken, getDevBypassSecret, config, clock }) — bearer/dev-bypass/timeout/401-retry
    ├── emitter.ts            # internal: same createEmitter<T>() shape as services/tts/emitter.ts
    └── service.test.ts       # boundary tests
```

The internal modules (`adapter.ts`, `apiFetch.ts`, `emitter.ts`) are not re-exported from `index.ts`. They exist only as a refactoring convenience inside `service.ts` — Ousterhout's "deep module" principle says the *interface* is small, not the *implementation*.

The shared `@rishi/shared/sync-engine` is imported only at the wiring site (`services/index.ts`), passed in as `engineFactory`. The service file itself imports nothing from `@rishi/shared/sync-engine` at runtime — only the `SyncDbAdapter` type from `@rishi/shared/sync-adapter` is used (`import type` only).

## Internals (orchestration flow)

```ts
// service.ts (illustrative — final implementation may differ in style but must match behavior)

export function createSyncService(deps: SyncServiceDeps): SyncService {
  const { ipc, engineFactory, connectivity, clock, windowEvents, config } = deps

  const emitter = createEmitter<SyncStatusSnapshot>()
  let engine: EngineLike | null = null
  let status: SyncStatus = 'not-synced'
  let lastSyncAt: number | null = null
  let intervalHandle: ReturnType<ClockPort['setInterval']> | null = null
  let writeDebounceHandle: ReturnType<ClockPort['setTimeout']> | null = null
  let connectivityUnsub: (() => void) | null = null
  let focusHandler: EventListener | null = null
  let started = false

  const apiFetch = makeApiFetch({
    fetch: deps.fetch,
    getAuthToken: deps.getAuthToken,
    getDevBypassSecret: deps.getDevBypassSecret,
    workerUrl: config.workerUrl,
    requestTimeoutMs: config.requestTimeoutMs,
    clock
  })

  function setStatus(next: SyncStatus): void {
    status = next
    emitter.emit({ status, lastSyncAt })
  }

  async function runSync(): Promise<void> {
    if (!engine) return
    if (status === 'syncing') return
    setStatus('syncing')
    try {
      await engine.sync()
      if (!engine) return // stopped mid-flight
      lastSyncAt = clock.now()
      setStatus('synced')
    } catch (err) {
      if (!engine) return
      if (err instanceof Error && err.message === 'AUTH_EXPIRED') {
        windowEvents.dispatchEvent(new CustomEvent('sync-auth-expired'))
        setStatus('error')
      } else if (!connectivity.isOnline()) {
        setStatus('offline')
      } else {
        setStatus('error')
      }
    }
  }

  return {
    start() {
      if (started) return
      started = true

      const adapter = makeAdapter(ipc)
      engine = engineFactory({ adapter, apiFetch })

      focusHandler = () => { void runSync() }
      windowEvents.addEventListener('focus', focusHandler)

      connectivityUnsub = connectivity.subscribe((online) => {
        if (online && status === 'offline') void runSync()
        if (!online) setStatus('offline')
      })

      intervalHandle = clock.setInterval(() => {
        if (connectivity.isOnline()) void runSync()
      }, config.intervalMs)

      void runSync()
    },

    stop() {
      if (!started) return
      started = false

      if (intervalHandle != null) clock.clearInterval(intervalHandle)
      intervalHandle = null

      if (writeDebounceHandle != null) clock.clearTimeout(writeDebounceHandle)
      writeDebounceHandle = null

      if (focusHandler) windowEvents.removeEventListener('focus', focusHandler)
      focusHandler = null

      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null

      engine = null
    },

    triggerWrite() {
      if (!started) return
      if (!connectivity.isOnline()) return
      if (writeDebounceHandle != null) clock.clearTimeout(writeDebounceHandle)
      writeDebounceHandle = clock.setTimeout(() => {
        writeDebounceHandle = null
        void runSync()
      }, config.debounceMs)
    },

    getStatus() {
      return { status, lastSyncAt }
    },

    onStatusChange(listener) {
      const unsub = emitter.on(listener)
      listener({ status, lastSyncAt })
      return unsub
    }
  }
}
```

### Behavioral notes baked into the contract

- **`start()` is idempotent.** Second call is a no-op. Mirrors today's `initDesktopSync` guard.
- **`stop()` is idempotent.** Calling stop on a service that was never started is a no-op. Tightens today's behavior (today's `destroyDesktopSync` is *almost* idempotent but leaves `engine = null` assignment unguarded).
- **In-flight sync survives `stop()`.** If `engine.sync()` is awaiting and `stop()` is called, the in-flight promise resolves but its status update is suppressed (`if (!engine) return`). No status flicker after stop.
- **`triggerWrite()` is gated.** No-op if not started or if connectivity is offline. The current behavior is "fire 2s later regardless of online status, and the sync itself fails offline." The new behavior short-circuits at the trigger, saving the engine.sync() call and the resulting `'error'` status flash.
- **Offline transitions immediately set status.** When connectivity flips to offline, status becomes `'offline'` even if no sync was in flight. When connectivity flips back to online *and* status was `'offline'`, a sync is kicked. Matches today's online/offline handlers.
- **Listener invoked immediately on subscribe.** Preserves today's behavior so `SyncStatusIndicator` can render its initial state from the subscription alone.
- **`AUTH_EXPIRED` dispatch is unchanged.** A `CustomEvent('sync-auth-expired')` flows through the `windowEvents` port. The auth-aware login flow that listens for this event continues to work — its `window.addEventListener('sync-auth-expired', ...)` registration is unchanged.

### Explicitly NOT added (YAGNI per the meta-spec scope guard)

- No public `triggerSync()` method. Internal only.
- No retry on engine.sync() transient failure. Today's `apiFetch` already retries 401 once with a fresh token; transient HTTP failures bubble up as `'error'` and the next interval / focus retries.
- No per-table status. The status is engine-wide.
- No queue of pending writes. The debounce coalesces; concurrent triggers are dropped via the in-flight guard.
- No partial progress events. Stage 2 candidate.
- No exponential backoff on repeated error. Stage 2 candidate.

Each of these is a candidate for Stage 2 Effect retrofit *if* Sync hits the rubric (predicted: it will), but is explicitly out of scope for Stage 1.

## Boundary test scenarios

All tests at the public interface. One file, `src/renderer/src/services/sync/service.test.ts`. Tests construct the service with fakes — no module-level mocks, no `vi.resetModules` between tests, no `window` polyfill.

### Test helpers (planned shape)

```ts
function makeIpc(): { ipc: SyncIpcChannels; calls: Record<keyof SyncIpcChannels, unknown[][]> }
function makeEngine(opts?: {
  syncImpl?: () => Promise<void>
  failWith?: Error
}): { engineFactory: EngineFactory; syncCount: () => number; engine: EngineLike }
function makeConnectivity(opts?: { initialOnline?: boolean }): ConnectivityPort & { setOnline(b: boolean): void }
function makeAuthToken(opts?: { token?: string | null }): () => Promise<string | null>
function makeClock(): ClockPort & { tick(ms: number): void; pendingTimers(): number }
function makeWindowEvents(): WindowEventsPort & {
  fire(type: string, event?: Event): void
  listeners(type: string): EventListener[]
}
function makeFetch(opts?: { status?: number; body?: unknown }): typeof fetch
```

The fakes are ~150 lines total — trivial. No `vi.mock` of `window`, `navigator`, or `setTimeout`.

### Boundary test scenarios (committed)

Minimum 10 tests, covering the major behaviors.

1. **`start()` kicks an initial sync and transitions `not-synced → syncing → synced`.** Setup: `engine.sync` resolves. Assert: status snapshot stream is `[not-synced, syncing, synced]`, `engine.sync` called exactly once, `lastSyncAt` set to `clock.now()` after success.
2. **`start()` is idempotent.** Setup: call `start()` twice. Assert: `engineFactory` invoked exactly once, `engine.sync` invoked exactly once (only the first start kicks the initial sync).
3. **`stop()` unregisters listeners, clears the interval, and is idempotent.** Setup: `start()` then `stop()` then `stop()`. Assert: `windowEvents.listeners('focus').length === 0`, `clock.pendingTimers() === 0`, second `stop()` does not throw.
4. **`triggerWrite()` debounces — multiple calls coalesce into one sync after `config.debounceMs`.** Setup: `start()`, wait for initial sync to complete. Call `triggerWrite()` 3 times in rapid succession (no clock advance between). Advance clock by `debounceMs - 1`. Assert: `engine.sync` count unchanged (still 1 from initial). Advance clock by 1. Assert: `engine.sync` count === 2.
5. **`triggerWrite()` is a no-op before `start()`.** Setup: do not call `start()`. Call `triggerWrite()`. Advance clock by `debounceMs * 2`. Assert: `engine.sync` never called.
6. **`triggerWrite()` is a no-op when offline.** Setup: `start()`, then `connectivity.setOnline(false)`. Call `triggerWrite()`. Advance clock by `debounceMs * 2`. Assert: `engine.sync` not called for the write trigger. (The initial sync that happens during `start()` may have already run before offline; the test resets `syncCount` after `start()` completes.)
7. **Online recovery from offline kicks a sync.** Setup: `start()`, then `connectivity.setOnline(false)` (status → `'offline'`), record current sync count. Then `connectivity.setOnline(true)`. Assert: `engine.sync` count incremented; status snapshot stream contains `'offline' → 'syncing' → 'synced'`.
8. **Offline transition sets status to `'offline'` immediately.** Setup: `start()` and let initial sync settle (status `'synced'`). Then `connectivity.setOnline(false)`. Assert: latest status snapshot is `{ status: 'offline', lastSyncAt: <previous> }`. No engine call required.
9. **Engine error classified as `'offline'` when connectivity reports offline mid-sync, else `'error'`.** Setup: two sub-tests. (a) `connectivity.isOnline() === false` at the moment `engine.sync()` rejects → status `'offline'`. (b) `connectivity.isOnline() === true` at the moment `engine.sync()` rejects → status `'error'`. Assert each.
10. **`AUTH_EXPIRED` dispatches `'sync-auth-expired'` custom event and sets status to `'error'`.** Setup: `engine.sync()` rejects with `new Error('AUTH_EXPIRED')`. Assert: `windowEvents.dispatchEvent` called with a `CustomEvent` whose `type === 'sync-auth-expired'`; final status snapshot is `{ status: 'error', ... }`.
11. **`onStatusChange` invokes the listener immediately on subscribe and again on every transition. Unsubscribe stops further notifications.** Setup: subscribe before `start()`. Assert: listener called once with `{ status: 'not-synced', lastSyncAt: null }`. Then `start()` and let the initial sync settle. Assert: listener called 3 more times (`syncing`, `synced`). Unsubscribe; trigger another sync. Assert: listener call count unchanged.
12. **Status updates after `stop()` are suppressed even if a sync is mid-flight.** Setup: `engine.sync` returns a controllable promise (test holds the resolver). Call `start()`. While `sync` is awaiting, call `stop()`. Resolve the sync's promise. Assert: no status snapshot emitted after the `stop()` call; final `getStatus()` is whatever it was at `stop()` time.

### Tests we explicitly do NOT add

- The exact wire format / shape of `engine.sync()`'s internals. The shared engine has its own tests.
- The 14 IPC methods of the adapter. The `makeAdapter(ipc)` factory's behavior is tested indirectly via the engine's calls to the adapter — but no test asserts "adapter method X calls ipc method Y with these args." Those would be re-implementing the existing `sync-adapter.test.ts` (which we delete). The adapter is now a private detail.
- The `apiFetch` wrapper's bearer / dev-bypass / 401-retry behavior at the unit level. Covered indirectly by integration tests that wire the engine factory to receive `apiFetch` and assert on `fetch` call shape. The `apiFetch` module gets *one* boundary test inside `service.test.ts`: "401 with valid token triggers a re-fetch with fresh token."
- The 5-minute interval firing at exactly 5 minutes. Tested as "interval fires at `config.intervalMs`" with a small `intervalMs` for test speed.
- Performance / throughput assertions.

### What inherited tests get deleted

Both `sync-triggers.test.ts` (2 tests, trivial) and `sync-adapter.test.ts` (14 tests, one per IPC method). Per the meta-spec: they describe shallow-module implementation, not service behavior. The replacement is the 12-test file above, which covers the same behavior at a higher level with cleaner fakes.

## Caller migration

| File | Current | After |
|---|---|---|
| `src/renderer/src/routes/__root.tsx` | `import { initDesktopSync, destroyDesktopSync } from '@/modules/sync-triggers'` + `useEffect(() => { initDesktopSync(); return () => destroyDesktopSync() }, [])` | `import { getSyncService } from '@/services'` + `useEffect(() => { const s = getSyncService(); s.start(); return () => s.stop() }, [])` |
| `src/renderer/src/components/SyncStatusIndicator.tsx` | `import { onSyncStatusChange } from '@/modules/sync-triggers'` + `useEffect(() => onSyncStatusChange(setStatus), [])` | `import { getSyncService } from '@/services'` + state is `SyncStatusSnapshot`; `useEffect(() => getSyncService().onStatusChange(setSnapshot), [])` — labels keyed off `snapshot.status` |
| `src/renderer/src/components/highlights/NoteEditor.tsx` | `import { triggerSyncOnWrite } from '@/modules/sync-triggers'` + 1 call | `import { getSyncService } from '@/services'` + `getSyncService().triggerWrite()` |
| `src/renderer/src/components/highlights/HighlightsPanel.tsx` | `import { triggerSyncOnWrite } from '@/modules/sync-triggers'` + 1 call | Same swap |
| `src/renderer/src/components/epub/EpubView.tsx` | `import { triggerSyncOnWrite } from '@/modules/sync-triggers'` + 2 calls | Same swap |
| `src/renderer/src/hooks/useChat.ts` | `import { triggerSyncOnWrite } from '@/modules/sync-triggers'` + 1 call | Same swap |

Total: 6 caller files touched. Five are mechanical 2-line changes (import + call site). The sixth (`SyncStatusIndicator`) is a small rewrite to consume the snapshot shape.

### `getStatus` callsite (none today)

No production caller of `getSyncStatus()` exists today outside `sync-triggers.ts` itself. The new `getStatus()` is provided for completeness and for `SyncStatusIndicator`'s initial-state read (via the `useState` initializer pattern shown in the usage example).

## Files / code to delete

| Location | What to remove |
|---|---|
| `src/renderer/src/modules/sync-triggers.ts` | Entire file — absorbed into `services/sync/service.ts` and `services/sync/apiFetch.ts` |
| `src/renderer/src/modules/sync-triggers.test.ts` | Replaced by `services/sync/service.test.ts` |
| `src/renderer/src/modules/sync-adapter.ts` | Entire file — absorbed into `services/sync/adapter.ts` (internal, not exported) |
| `src/renderer/src/modules/sync-adapter.test.ts` | Replaced by `services/sync/service.test.ts` (adapter behavior covered indirectly) |

Per the meta-spec's *no shims* rule: no compatibility re-exports. One PR, one source of truth.

## Out of scope

- **Main-process IPC handlers** (`src/main/ipc/sync.ts`) — untouched. Their surface stays as-is.
- **Shared `@rishi/shared/sync-engine` and `@rishi/shared/sync-adapter`** — untouched. Owned by the shared package.
- **`SyncStatusIndicator` layout / styling** — only the import and snapshot shape change.
- **The `connectivityActor` xstate machine** — not consumed by Sync. Sync consumes the higher-level boolean port.
- **Connectivity service refactor** — separately specced. When it lands, Sync's wiring site swaps one import.
- **`'sync-auth-expired'` listener** in the auth-aware login flow — its `window.addEventListener` registration is unchanged because the service dispatches the event through `windowEvents` (which points at the real `window` in production).

## Development workflow — TDD

Strict TDD: red → green → commit per behavior. Each test-implementation pair is its own commit. No "implement everything then write tests" commits.

### PR commit sequence

1. **Scaffold.** Create `services/sync/` folder with `types.ts` (full type definitions) and empty stubs in `service.ts`, `adapter.ts`, `apiFetch.ts`, `emitter.ts` that throw "not implemented" from each method. Set up `service.test.ts` with `makeIpc()`, `makeEngine()`, `makeConnectivity()`, `makeAuthToken()`, `makeClock()`, `makeWindowEvents()`, `makeFetch()` helpers. Commit.
2. **Test 1 + impl (`start()` kicks initial sync).** Write Test 1. Red. Implement `start()` + `runSync()` + emitter wiring + adapter factory + engineFactory invocation. Green. Commit.
3. **Test 2 + impl (`start()` idempotent).** Write Test 2. Red. Add the `started` guard. Green. Commit.
4. **Test 3 + impl (`stop()` clean teardown + idempotent).** Write Test 3. Red. Implement `stop()` — clear interval, clear debounce, remove focus listener, unsub connectivity, drop engine. Green. Commit.
5. **Test 4 + impl (`triggerWrite` debounces).** Write Test 4. Red. Implement debounce via injected clock. Green. Commit.
6. **Test 5 + impl (`triggerWrite` no-op before `start`).** Write Test 5. Red. Add guard. Green. Commit.
7. **Test 6 + impl (`triggerWrite` no-op when offline).** Write Test 6. Red. Add connectivity gate. Green. Commit.
8. **Test 7 + impl (online recovery kicks sync).** Write Test 7. Red. Implement connectivity.subscribe handler. Green. Commit.
9. **Test 8 + impl (offline transition sets status).** Write Test 8. Red. Refine subscribe handler. Green. Commit.
10. **Test 9 + impl (error classification on engine failure).** Write Test 9. Red. Implement catch block branching. Green. Commit.
11. **Test 10 + impl (AUTH_EXPIRED dispatch).** Write Test 10. Red. Add the special-case dispatch through `windowEvents`. Green. Commit.
12. **Test 11 + impl (`onStatusChange` immediate + transitions).** Write Test 11. Red. Implement subscribe semantics. Green. Commit.
13. **Test 12 + impl (status suppression after stop).** Write Test 12. Red. Add `if (!engine) return` guards after async boundaries. Green. Commit.
14. **`apiFetch` integration test.** Write a focused test asserting that on a 401 response with a valid token, `fetch` is called twice (second time with a fresh token). Red. Implement `apiFetch.ts` retry-with-fresh-token. Green. Commit.
15. **Wiring + caller migrations.** Add `getSyncService()` to `services/index.ts`; migrate the 6 callers; update `SyncStatusIndicator` to consume the snapshot shape. No new tests (composition, not behavior). Commit.
16. **Delete old files + tests** in one commit: `sync-triggers.ts`, `sync-triggers.test.ts`, `sync-adapter.ts`, `sync-adapter.test.ts`.
17. **Final verification.** `tsc` / `eslint` / `vitest` clean across the app.

Each step is one commit. Steps 2-14 are red-green pairs; the rest are mechanical.

### Expected diff

- **Added:** ~650 lines (service + tests + types + emitter + adapter + apiFetch + wiring).
- **Removed:** ~400 lines (old triggers + adapter + their 2 test files).
- **Net:** slightly positive. The deep-module discipline removes the implicit "free function + module state" pattern in favor of explicit ports, which has a small line-count cost but a large testability gain.

## Open questions

These are open design questions the implementation plan should resolve. They are flagged but **not** decided in this spec.

1. **How much of the shared sync-engine's event surface should the service re-export?** *Lean: none of it — only the high-level `SyncStatus` discriminated union is part of the service's contract. Engine-specific events (push count, pull count, per-record progress) stay internal to the engine; if a future caller needs them, they bubble up through a service-level addition.* Rationale: the engine has no event surface today (`sync()` returns `Promise<void>`), so re-exporting nothing matches reality. Stage 2 is the right time to revisit if Effect adoption surfaces typed progress streams.
2. **Should `start()` be idempotent?** *Lean: yes — current `initDesktopSync` is already.* Confirmed in decision summary. The plan should verify there are no callers relying on "second `start()` triggers a re-sync" (today there aren't).
3. **Where does the `connectivity` port come from in the wiring site — `getConnectivityService()` (not yet built) or directly from `modules/connectivity.ts`?** *Lean: direct module import for now; revisit when Connectivity service refactor lands.* The Sync wiring site builds the `ConnectivityPort` from `modules/connectivity.ts`'s actor + `isOnline()` until the Connectivity service ships its own `getConnectivityService()` factory. At that point, the Sync wiring site changes to `const connectivity = getConnectivityService()` and the adapter shim is deleted. The service-internal port shape is unchanged.
4. **Is the tiny `createEmitter<T>` duplicated or imported from `services/tts/emitter.ts`?** *Lean: duplicate it inside `services/sync/emitter.ts`* — services should not depend on each other's internals. Both files are 20 lines; the duplication is trivial. If a third service wants the same primitive, lift to `services/_shared/emitter.ts`.
5. **Should `start()` accept an optional `{ kickInitialSync?: boolean }` flag?** *Lean: no.* Today's behavior is always-kick, every caller expects always-kick, no test scenario benefits. Add only if a real caller demands it.

## Stage 2 outlook

Stage 2 is explicit Effect-TS adoption *inside* a service, after Stage 1 ships. The meta-spec sets a rubric: Effect goes into a service only if it scores positively on ≥2 of 5 axes.

### Scoring Sync against the rubric

| Axis | Score | Why |
|---|---|---|
| **Concurrency** | YES | Online-gated sync coalescing, in-flight guard, debounce coalescing — `Semaphore` + `Queue` model this cleanly. |
| **Retry / scheduling** | YES | Periodic interval (every `intervalMs`), debounce (`debounceMs`), online-recovery retry, future exponential backoff on transient HTTP failure — `Schedule.spaced` / `Schedule.exponential` / `Schedule.fixed` cover all four. |
| **Resource lifecycle** | PARTIAL | The `start()` / `stop()` lifecycle is a textbook `Scope` use case — every listener registration becomes `acquireRelease`, and `stop()` becomes `Scope.close`. But there's no acquired *resource* in the traditional sense (no sockets, no streams). Effect would simplify cleanup but not unlock new behavior. |
| **Typed error channels** | PARTIAL | Three error categories today (auth-expired, offline, generic engine error) but the service consumers don't switch on them — they consume the derived status enum. Effect would *enable* exhaustive error handling but no caller demands it. |
| **Composed async pipeline** | YES | The trigger → debounce → connectivity-gate → in-flight-guard → engine.sync → status-update flow is a sequenced async pipeline with branching on three independent inputs (focus, online, interval, triggerWrite). `Effect.gen` + `Stream` + `Hub` would compress the four event sources into one observable program. |

**Score:** 3 firm yeses + 2 partials = strong yes. Sync is a likely Stage 2 candidate, second after TTS.

### Stage 2 sketch

The public interface stays plain TS (`void` from `start` / `stop` / `triggerWrite`, callback-based `onStatusChange`, plain `SyncStatusSnapshot` return). Internally:

- **Event sources → `Stream` or `Hub`.** The four trigger inputs (`focus` event, online transition, interval tick, debounced `triggerWrite`) become one `Stream<SyncTriggerEvent>` consumed by a single fiber. The four imperative event handlers collapse.
- **In-flight guard → `Semaphore.make(1)`.** The `if (status === 'syncing') return` guard becomes a permit acquisition. Drop the explicit guard.
- **Debounce → `Stream.debounce(config.debounceMs)`.** The hand-rolled `setTimeout` + `clearTimeout` becomes one operator on the trigger stream.
- **Connectivity gate → `Stream.filter` + `Stream.merge` against `Stream` of connectivity transitions.** The "no-op if offline" branch and "online recovery" branch unify into one stream-filtering rule.
- **Status emission → `SubscriptionRef<SyncStatusSnapshot>`.** Replaces the `createEmitter<T>` + module-scoped state. `onStatusChange` becomes `SubscriptionRef.changes` consumed via `Effect.runFork`.
- **Lifecycle → `Scope`.** `start()` opens a scope; every listener is registered via `acquireRelease`; `stop()` closes the scope; cleanup is automatic. The `if (!engine) return` post-await guards disappear because in-flight effects are interrupted.
- **Public boundary.** `Effect.runFork(programWithScope)` at `start()`; `Scope.close(scope)` at `stop()`. Callers don't change.

The interface contract from Stage 1 is preserved exactly. The internals shrink. The interval + debounce + online-gating + in-flight-guard logic becomes a 30-line `Stream` program.

### Stage 2 trigger

Per the meta-spec, Stage 2 starts only after **all six Stage 1 services have shipped**. This spec commits no Stage 2 work. The sketch above exists so the team can validate the public interface won't need to break when Stage 2 lands.

### Stopping rule

Per the meta-spec: if Stage 2 ergonomics are painful when TTS is retrofitted first, Effect is dropped from Stage 2 entirely and Sync stays plain TS. The Stage 1 service from this spec is *unaffected* by that outcome — its public interface is the durable artifact.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/sync/index.ts` is the single public-facing module exporting `createSyncService`, `SyncService`, and the public types.
2. `src/renderer/src/services/index.ts` exports a `getSyncService()` lazy singleton.
3. All 6 callers (`__root.tsx`, `SyncStatusIndicator.tsx`, `NoteEditor.tsx`, `HighlightsPanel.tsx`, `EpubView.tsx`, `useChat.ts`) import from `@/services`.
4. The 2 old module files plus 2 old test files are **deleted**, not kept as shims.
5. All 12 boundary tests pass.
6. `tsc`, `eslint`, `vitest` clean across the app.
