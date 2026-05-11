# Sync service refactor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `sync-triggers` + `sync-adapter` into a single deep `services/sync/` module with a typed factory boundary, injected ports for `ipc` / `engineFactory` / `fetch` / `getAuthToken` / `getDevBypassSecret` / `connectivity` / `clock` / `windowEvents` / `config`, typed `onStatusChange` subscriptions (no leaked listener pattern), and a converged boundary test suite.

**Architecture:** One factory `createSyncService(deps: SyncServiceDeps)`. Dependencies injected at the boundary. The shared `@rishi/shared/sync-engine` stays external and is consumed via the `engineFactory` port. Connectivity is consumed through a port matching the existing `modules/connectivity.ts` shape (no direct `navigator.onLine` reads). Status events use the same typed `Emitter<T>` pattern from TTS.

**Tech Stack:** TypeScript, vitest, `@rishi/shared/sync-engine` (internal), Electron IPC (via injected port).

**Spec:** [`docs/superpowers/specs/2026-05-11-sync-service-design.md`](../specs/2026-05-11-sync-service-design.md)

**Parent meta-spec:** [`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md`](../specs/2026-05-11-services-and-effect-adoption-design.md)

---

## Plan overview

- **Task 0 — Worktree + scaffold:** The orchestrator created a worktree at `/tmp/rishi-sync-refactor` from `origin/main` on branch `refactor/sync-service`. Scaffold the empty service directory.
- **Tasks 1–7 — Build the service (TDD):** Types → emitter helper → adapter → debounce helper → service factory → public exports. Each behavior gets its own RED/GREEN/COMMIT cycle.
- **Tasks 8–13 — Wire & migrate callers:** Add `getSyncService()` to `services/index.ts`, then migrate `__root.tsx`, `NoteEditor`, `HighlightsPanel`, `EpubView`, `useChat`, and `SyncStatusIndicator`.
- **Task 14 — Delete old modules:** Remove `sync-triggers.ts`, `sync-adapter.ts`, and their tests.
- **Task 15 — Final verification.** `pnpm typecheck`, `pnpm lint`, `pnpm vitest run`.

All paths below are absolute from `/tmp/rishi-sync-refactor` (the worktree root). All `pnpm` commands should be run from `/tmp/rishi-sync-refactor/apps/rishi-electron` unless otherwise stated. All `git` commands should be run from `/tmp/rishi-sync-refactor`.

---

## Task 0: Worktree + scaffold

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/index.ts` (placeholder)

- [ ] **Step 1: Confirm the worktree exists and is on the expected branch**

```bash
cd /tmp/rishi-sync-refactor
git status -sb
```

Expected output starts with `## refactor/sync-service` and shows a clean tree. If the worktree is missing, ask the orchestrator to create it via `git worktree add /tmp/rishi-sync-refactor -b refactor/sync-service origin/main`.

- [ ] **Step 2: Verify no stale sync edits exist in the worktree**

```bash
cd /tmp/rishi-sync-refactor
git status -s -- apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts \
                  apps/rishi-electron/src/renderer/src/modules/sync-adapter.ts \
                  apps/rishi-electron/src/renderer/src/services/sync
```

Expected: no output (clean).

- [ ] **Step 3: Create the empty service directory with a placeholder `index.ts`**

```bash
mkdir -p /tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync
```

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/index.ts`:

```ts
// Placeholder — populated incrementally by subsequent tasks.
export {}
```

- [ ] **Step 4: Verify typecheck still passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes. (Pre-existing typecheck noise in `src/main/**` and `stores/navStore.test.ts` is out of scope — see Task 15.)

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/index.ts
git commit -m "refactor(sync): scaffold services/sync directory

Empty index.ts placeholder. Behavior added incrementally in subsequent
commits (TDD: red → green → commit per behavior)."
```

---

## Task 1: Type definitions (`types.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/types.ts`

- [ ] **Step 1: Create `types.ts` with the full public type surface**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/types.ts`:

```ts
import type { SyncDbAdapter } from '@rishi/shared/sync-adapter'

/**
 * The five disjoint sync states. Mirrors the legacy
 * `modules/sync-triggers.ts` union exactly.
 */
export type SyncStatus = 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline'

/**
 * Snapshot returned by `getStatus()` and emitted on every transition.
 * `lastSyncAt` is epoch ms of the last *successful* sync, or null if
 * none has succeeded yet.
 */
export interface SyncStatusSnapshot {
  status: SyncStatus
  lastSyncAt: number | null
}

export type SyncStatusListener = (snapshot: SyncStatusSnapshot) => void

/**
 * Exactly the 17 `window.electron.sync*` IPC methods the renderer adapter
 * marshals. No other `window.electron.*` surface leaks into the service.
 */
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
  syncApplyConversationConflict(
    conflict: Record<string, unknown>,
    syncVersion: number
  ): Promise<void>

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
  /** Periodic sync interval. Default 5 * 60 * 1000. */
  intervalMs: number
  /** Debounce window for `triggerWrite()`. Default 2000. */
  debounceMs: number
  /** Per-request HTTP timeout for sync push/pull. Default 30000. */
  requestTimeoutMs: number
}

export interface ConnectivityPort {
  isOnline(): boolean
  /** Listener fires on transitions only. Returns an unsubscribe fn. */
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

/** What the service treats as an engine — narrowed from `@rishi/shared/sync-engine`. */
export interface EngineLike {
  sync(): Promise<void>
}

export interface EngineFactoryConfig {
  adapter: SyncDbAdapter
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

export interface SyncService {
  /**
   * Construct the engine (if not yet built), register focus / online /
   * offline / interval listeners, kick an initial sync. Idempotent.
   */
  start(): void
  /**
   * Unregister every listener, clear the interval and any pending debounce,
   * drop the engine reference. Idempotent.
   */
  stop(): void
  /**
   * Schedule a sync after `config.debounceMs`. Repeated calls within the
   * window coalesce. No-op if not started or if connectivity reports offline.
   */
  triggerWrite(): void
  /**
   * Snapshot of the current sync status. Safe to call before `start()`.
   */
  getStatus(): SyncStatusSnapshot
  /**
   * Subscribe to status-change events. The listener is invoked **immediately
   * on subscribe** with the current snapshot, then again on every transition.
   * Returns an unsubscribe function.
   */
  onStatusChange(listener: SyncStatusListener): () => void
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes (types only — no behavior).

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/types.ts
git commit -m "refactor(sync): add public type surface (SyncService, SyncServiceDeps, ports)

Discriminated SyncStatus union + SyncStatusSnapshot mirror the legacy
status shape. Nine ports (ipc, engineFactory, fetch, getAuthToken,
getDevBypassSecret, connectivity, clock, windowEvents, config) push
every transitive dependency to the wiring site. SyncDbAdapter is a
type-only import from @rishi/shared/sync-adapter."
```

---

## Task 2: Emitter helper — RED

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/emitter.test.ts`

The Sync service uses the same tiny typed-emitter primitive as TTS. Per the spec's Open Question 4, we duplicate (not import) the helper so services do not depend on each other's internals.

- [ ] **Step 1: Write the failing test for the typed Emitter**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/emitter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('delivers emitted values to a subscribed listener', () => {
    const e = createEmitter<{ value: number }>()
    const listener = vi.fn()
    e.on(listener)

    e.emit({ value: 42 })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith({ value: 42 })
  })

  it('fans an emit out to every subscriber', () => {
    const e = createEmitter<string>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit('hello')

    expect(a).toHaveBeenCalledWith('hello')
    expect(b).toHaveBeenCalledWith('hello')
  })

  it('returns an unsubscribe function that removes the listener', () => {
    const e = createEmitter<number>()
    const listener = vi.fn()
    const unsubscribe = e.on(listener)

    e.emit(1)
    unsubscribe()
    e.emit(2)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(1)
  })
})
```

- [ ] **Step 2: Run the test — expect RED (module not found)**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/sync/emitter.test.ts
```

Expected: 3 tests fail with `Cannot find module './emitter'`.

---

## Task 3: Emitter helper — GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/emitter.ts`

- [ ] **Step 1: Implement `createEmitter`**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/emitter.ts`:

```ts
/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 *
 * Duplicated from services/tts/emitter.ts per design Open Question 4
 * (services should not depend on each other's internals). If a third
 * service wants the same primitive, lift to services/_shared/emitter.ts.
 */
export interface Emitter<T> {
  emit(payload: T): void
  on(listener: (payload: T) => void): () => void
}

export function createEmitter<T>(): Emitter<T> {
  const listeners = new Set<(payload: T) => void>()
  return {
    emit(payload) {
      for (const listener of listeners) listener(payload)
    },
    on(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/emitter.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/emitter.ts \
        apps/rishi-electron/src/renderer/src/services/sync/emitter.test.ts
git commit -m "test(sync): typed Emitter helper with unsubscribe returns

Tiny utility — ~15 LOC. Duplicates services/tts/emitter.ts deliberately
so services stay independent. The on() function returns an unsubscribe
handle (canonical idiom)."
```

---

## Task 4: Adapter — RED (dirty-record marshaling)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/adapter.test.ts`

The internal `makeAdapter(ipc)` factory marshals the raw IPC payloads into the typed `SyncDbAdapter` shape expected by `@rishi/shared/sync-engine`. The DB returns rows with `Date | string | number` timestamps that need to be coerced to epoch ms.

- [ ] **Step 1: Write the failing test for `getDirtyBooks` row coercion**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/adapter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type { SyncIpcChannels } from './types'
import { makeAdapter } from './adapter'

/**
 * Build an in-memory SyncIpcChannels backed by per-channel arrays/values.
 * Exposes vi.fn spies on every method so tests can assert call args.
 */
export function makeIpc(initial?: {
  books?: unknown[]
  highlights?: unknown[]
  conversations?: unknown[]
  messages?: unknown[]
  lastVersion?: number
}): SyncIpcChannels {
  return {
    syncGetDirtyBooks: vi.fn(async () => initial?.books ?? []),
    syncGetDirtyHighlights: vi.fn(async () => initial?.highlights ?? []),
    syncGetDirtyConversations: vi.fn(async () => initial?.conversations ?? []),
    syncGetDirtyMessages: vi.fn(async () => initial?.messages ?? []),
    syncGetLastVersion: vi.fn(async () => initial?.lastVersion ?? 0),
    syncMarkBooksClean: vi.fn(async () => {}),
    syncMarkHighlightsClean: vi.fn(async () => {}),
    syncMarkConversationsClean: vi.fn(async () => {}),
    syncMarkMessagesClean: vi.fn(async () => {}),
    syncApplyBookConflict: vi.fn(async () => {}),
    syncApplyHighlightConflict: vi.fn(async () => {}),
    syncApplyConversationConflict: vi.fn(async () => {}),
    syncUpsertBook: vi.fn(async () => {}),
    syncUpsertHighlight: vi.fn(async () => {}),
    syncUpsertConversation: vi.fn(async () => {}),
    syncInsertMessage: vi.fn(async () => {}),
    syncUpdateLastVersion: vi.fn(async () => {})
  }
}

describe('adapter.getDirtyBooks', () => {
  it('coerces a row with a Date updatedAt into epoch ms and forwards every field', async () => {
    const ipc = makeIpc({
      books: [
        {
          syncId: 'book-1',
          title: 'Title',
          author: 'Author',
          format: 'epub',
          currentCfi: 'epubcfi(/6)',
          currentPage: 12,
          fileHash: 'abc',
          fileR2Key: 'r2/key',
          coverR2Key: 'r2/cover',
          createdAt: new Date(1_700_000_000_000),
          updatedAt: 1_700_000_001_000,
          syncVersion: 3,
          isDeleted: 0
        }
      ]
    })
    const adapter = makeAdapter(ipc)

    const rows = await adapter.getDirtyBooks()

    expect(rows).toHaveLength(1)
    expect(rows[0]).toEqual({
      id: 'book-1',
      title: 'Title',
      author: 'Author',
      format: 'epub',
      currentCfi: 'epubcfi(/6)',
      currentPage: 12,
      fileHash: 'abc',
      fileR2Key: 'r2/key',
      coverR2Key: 'r2/cover',
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_001_000,
      syncVersion: 3,
      isDirty: true,
      isDeleted: false
    })
  })
})
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/sync/adapter.test.ts
```

Expected: 1 test fails — `Cannot find module './adapter'`.

---

## Task 5: Adapter — GREEN (dirty-record marshaling)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/adapter.ts`

- [ ] **Step 1: Implement `makeAdapter` with dirty-getter coverage for all four tables**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/adapter.ts`:

```ts
/**
 * Sync adapter — marshals raw IPC payloads into the typed SyncDbAdapter
 * shape expected by `@rishi/shared/sync-engine`. Internal to the service;
 * not exported from `index.ts`.
 *
 * Replaces the class-based `modules/sync-adapter.ts`. Stateless — every
 * method is a one-line `await ipc.X(...)` plus row coercion.
 */
import type {
  SyncDbAdapter,
  SyncBook,
  SyncHighlight,
  SyncConversation,
  SyncMessage
} from '@rishi/shared/sync-adapter'
import type { SyncIpcChannels } from './types'

/** Coerce Date | number | string to epoch ms. Falls back to `Date.now()`. */
function toTimestamp(val: unknown): number {
  if (val instanceof Date) return val.getTime()
  if (typeof val === 'number') return val
  if (typeof val === 'string') return new Date(val).getTime()
  return Date.now()
}

export function makeAdapter(ipc: SyncIpcChannels): SyncDbAdapter {
  return {
    async getDirtyBooks(): Promise<SyncBook[]> {
      const rows = (await ipc.syncGetDirtyBooks()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.syncId as string,
        title: row.title as string,
        author: row.author as string,
        format: (row.format ?? row.kind) as string,
        currentCfi: row.currentCfi as string | null,
        currentPage: row.currentPage as number | null,
        fileHash: row.fileHash as string,
        fileR2Key: row.fileR2Key as string | null,
        coverR2Key: row.coverR2Key as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyHighlights(): Promise<SyncHighlight[]> {
      const rows = (await ipc.syncGetDirtyHighlights()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        bookId: row.bookId as string,
        cfiRange: row.cfiRange as string,
        text: row.text as string,
        color: row.color as string,
        note: row.note as string | null,
        chapter: row.chapter as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyConversations(): Promise<SyncConversation[]> {
      const rows = (await ipc.syncGetDirtyConversations()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        bookId: row.bookId as string,
        title: row.title as string,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getDirtyMessages(): Promise<SyncMessage[]> {
      const rows = (await ipc.syncGetDirtyMessages()) as Array<Record<string, unknown>>
      return rows.map((row) => ({
        id: row.id as string,
        conversationId: row.conversationId as string,
        role: row.role as string,
        content: row.content as string,
        sourceChunks: row.sourceChunks as string | null,
        createdAt: toTimestamp(row.createdAt),
        updatedAt: toTimestamp(row.updatedAt),
        syncVersion: row.syncVersion as number,
        isDirty: true,
        isDeleted: row.isDeleted === 1
      }))
    },

    async getLastSyncVersion(): Promise<number> {
      return ipc.syncGetLastVersion()
    },

    async applyBookConflict(c, syncVersion) {
      await ipc.syncApplyBookConflict(c, syncVersion)
    },
    async applyHighlightConflict(c, syncVersion) {
      await ipc.syncApplyHighlightConflict(c, syncVersion)
    },
    async applyConversationConflict(c, syncVersion) {
      await ipc.syncApplyConversationConflict(c, syncVersion)
    },

    async markBooksClean(ids, syncVersion) {
      await ipc.syncMarkBooksClean(ids, syncVersion)
    },
    async markHighlightsClean(ids, syncVersion) {
      await ipc.syncMarkHighlightsClean(ids, syncVersion)
    },
    async markConversationsClean(ids, syncVersion) {
      await ipc.syncMarkConversationsClean(ids, syncVersion)
    },
    async markMessagesClean(ids, syncVersion) {
      await ipc.syncMarkMessagesClean(ids, syncVersion)
    },

    async upsertRemoteBook(remote) {
      await ipc.syncUpsertBook(remote)
    },
    async upsertRemoteHighlight(remote) {
      await ipc.syncUpsertHighlight(remote)
    },
    async upsertRemoteConversation(remote) {
      await ipc.syncUpsertConversation(remote)
    },
    async insertRemoteMessage(remote) {
      await ipc.syncInsertMessage(remote)
    },

    async updateLastSyncVersion(version) {
      await ipc.syncUpdateLastVersion(version)
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/adapter.test.ts
```

Expected: 1 test passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/adapter.ts \
        apps/rishi-electron/src/renderer/src/services/sync/adapter.test.ts
git commit -m "test(sync): adapter marshals dirty books with row coercion

makeAdapter(ipc) builds a SyncDbAdapter from the injected IPC port —
replaces the class-based DesktopSyncAdapter as an internal factory.
toTimestamp() coerces Date|number|string DB shapes to epoch ms."
```

---

## Task 6: Adapter — pass-through methods (conflict / mark-clean / pull)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/adapter.test.ts`

- [ ] **Step 1: Add three tests covering mark-clean, conflict, and pull pass-through**

Append to `adapter.test.ts`:

```ts
describe('adapter pass-through', () => {
  it('markHighlightsClean forwards ids + version verbatim to ipc', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)

    await adapter.markHighlightsClean(['h-1', 'h-2'], 7)

    expect(ipc.syncMarkHighlightsClean).toHaveBeenCalledTimes(1)
    expect(ipc.syncMarkHighlightsClean).toHaveBeenCalledWith(['h-1', 'h-2'], 7)
  })

  it('applyBookConflict forwards the conflict object + version verbatim', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)
    const conflict = { id: 'b-1', updatedAt: 9 }

    await adapter.applyBookConflict(conflict, 12)

    expect(ipc.syncApplyBookConflict).toHaveBeenCalledWith(conflict, 12)
  })

  it('upsertRemoteHighlight forwards the remote record + updateLastSyncVersion forwards the version', async () => {
    const ipc = makeIpc()
    const adapter = makeAdapter(ipc)
    const remote = { id: 'h-9', text: 'remote text' }

    await adapter.upsertRemoteHighlight(remote)
    await adapter.updateLastSyncVersion(99)

    expect(ipc.syncUpsertHighlight).toHaveBeenCalledWith(remote)
    expect(ipc.syncUpdateLastVersion).toHaveBeenCalledWith(99)
  })
})
```

- [ ] **Step 2: Run tests — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/adapter.test.ts
```

Expected: 4 tests pass (the implementation is already complete from Task 5).

- [ ] **Step 3: Commit (test-only)**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/adapter.test.ts
git commit -m "test(sync): adapter mark-clean / conflict / pull methods pass through to ipc"
```

---

## Task 7: Debounce helper — RED

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/debounce.test.ts`

A small `createDebouncer(clock, delayMs)` so the service does not hand-roll `setTimeout` / `clearTimeout` against the injected clock at the top level. Internal-only.

- [ ] **Step 1: Add the test helper + first failing tests**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/debounce.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import type { ClockPort } from './types'
import { createDebouncer } from './debounce'

/**
 * Virtual clock with manual tick advancement. Models setTimeout /
 * clearTimeout / setInterval / clearInterval against an internal queue.
 */
export function makeClock(): ClockPort & {
  tick(ms: number): void
  pendingTimers(): number
} {
  type Entry = {
    id: number
    runAt: number
    fn: () => void
    intervalMs: number | null
  }
  let now = 0
  let nextId = 1
  const entries = new Map<number, Entry>()

  function runUntil(target: number): void {
    while (true) {
      let next: Entry | null = null
      for (const e of entries.values()) {
        if (e.runAt <= target && (next === null || e.runAt < next.runAt)) next = e
      }
      if (!next) break
      now = next.runAt
      if (next.intervalMs == null) {
        entries.delete(next.id)
      } else {
        next.runAt += next.intervalMs
      }
      next.fn()
    }
    now = target
  }

  return {
    now: () => now,
    setTimeout(fn, ms) {
      const id = nextId++
      entries.set(id, { id, runAt: now + ms, fn, intervalMs: null })
      return id as unknown as ReturnType<typeof setTimeout>
    },
    clearTimeout(handle) {
      entries.delete(handle as unknown as number)
    },
    setInterval(fn, ms) {
      const id = nextId++
      entries.set(id, { id, runAt: now + ms, fn, intervalMs: ms })
      return id as unknown as ReturnType<typeof setInterval>
    },
    clearInterval(handle) {
      entries.delete(handle as unknown as number)
    },
    tick(ms) {
      runUntil(now + ms)
    },
    pendingTimers() {
      return entries.size
    }
  }
}

describe('createDebouncer', () => {
  it('runs the callback once after the delay window elapses', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    clock.tick(99)
    expect(cb).not.toHaveBeenCalled()
    clock.tick(1)
    expect(cb).toHaveBeenCalledTimes(1)
  })

  it('coalesces consecutive triggers within the window into a single run', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    clock.tick(50)
    d.trigger(cb)
    clock.tick(50) // 100ms since first trigger, but only 50ms since second
    expect(cb).not.toHaveBeenCalled()
    clock.tick(50)
    expect(cb).toHaveBeenCalledTimes(1)
  })

  it('cancel() drops the pending callback', () => {
    const clock = makeClock()
    const cb = vi.fn()
    const d = createDebouncer(clock, 100)

    d.trigger(cb)
    expect(d.isPending()).toBe(true)
    d.cancel()
    expect(d.isPending()).toBe(false)
    clock.tick(200)
    expect(cb).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/sync/debounce.test.ts
```

Expected: 3 tests fail — `Cannot find module './debounce'`.

---

## Task 8: Debounce helper — GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/debounce.ts`

- [ ] **Step 1: Implement `createDebouncer`**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/debounce.ts`:

```ts
import type { ClockPort } from './types'

/**
 * Tiny clock-injected debouncer. Each `trigger(fn)` resets the timer;
 * the most recently passed `fn` runs after `delayMs` of quiet. Internal
 * to the service — not exported from `index.ts`.
 */
export interface Debouncer {
  trigger(fn: () => void): void
  cancel(): void
  isPending(): boolean
}

export function createDebouncer(clock: ClockPort, delayMs: number): Debouncer {
  let handle: ReturnType<ClockPort['setTimeout']> | null = null
  return {
    trigger(fn) {
      if (handle != null) clock.clearTimeout(handle)
      handle = clock.setTimeout(() => {
        handle = null
        fn()
      }, delayMs)
    },
    cancel() {
      if (handle != null) {
        clock.clearTimeout(handle)
        handle = null
      }
    },
    isPending() {
      return handle != null
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/debounce.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/debounce.ts \
        apps/rishi-electron/src/renderer/src/services/sync/debounce.test.ts
git commit -m "test(sync): clock-injected debouncer with trigger/cancel/isPending

Replaces the module-scoped writeTimeout let in sync-triggers.ts. The
fake clock from the test file (makeClock) reappears in service.test.ts —
extracted so debounce tests are deterministic without sleeps."
```

---

## Task 9: Service factory — `start()` kicks initial sync (RED)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

The boundary tests live in this one file. All fakes are defined at the top so every test composes them with literal `createSyncService({...})` calls — no module-level mocks, no `vi.resetModules`.

- [ ] **Step 1: Create `service.test.ts` with shared test helpers + the first failing test**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createSyncService } from './service'
import type {
  ConnectivityPort,
  EngineFactory,
  EngineLike,
  SyncConfig,
  SyncServiceDeps,
  WindowEventsPort
} from './types'
import { makeIpc } from './adapter.test'
import { makeClock } from './debounce.test'

/**
 * Build an engine factory that returns a controllable `{ sync }`. The
 * caller can pass `syncImpl` to override the default no-op resolution.
 */
export function makeEngine(opts?: {
  syncImpl?: () => Promise<void>
}): { engineFactory: EngineFactory; engine: EngineLike; syncCount: () => number } {
  let count = 0
  const sync = vi.fn(async () => {
    count++
    if (opts?.syncImpl) return opts.syncImpl()
  })
  const engine: EngineLike = { sync }
  const engineFactory: EngineFactory = vi.fn(() => engine)
  return { engineFactory, engine, syncCount: () => count }
}

export function makeConnectivity(opts?: {
  initialOnline?: boolean
}): ConnectivityPort & { setOnline(b: boolean): void } {
  let online = opts?.initialOnline ?? true
  const listeners = new Set<(b: boolean) => void>()
  return {
    isOnline: () => online,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    setOnline(b) {
      if (b === online) return
      online = b
      for (const l of [...listeners]) l(b)
    }
  }
}

export const makeAuthToken = (token: string | null = 'test-bearer') =>
  vi.fn(async () => token)

export const makeDevBypass = (secret: string | null = null) => vi.fn(async () => secret)

export function makeWindowEvents(): WindowEventsPort & {
  fire(type: string, event?: Event): void
  listeners(type: string): EventListener[]
} {
  const map = new Map<string, Set<EventListener>>()
  const dispatched: Event[] = []
  return {
    addEventListener(type, listener) {
      if (!map.has(type)) map.set(type, new Set())
      map.get(type)!.add(listener)
    },
    removeEventListener(type, listener) {
      map.get(type)?.delete(listener)
    },
    dispatchEvent(event) {
      dispatched.push(event)
      for (const l of map.get(event.type) ?? []) l(event)
    },
    fire(type, event) {
      for (const l of map.get(type) ?? []) l(event ?? new Event(type))
    },
    listeners(type) {
      return [...(map.get(type) ?? [])]
    }
  }
}

export const baseConfig: SyncConfig = {
  workerUrl: 'https://api.example.com',
  intervalMs: 10_000,
  debounceMs: 100,
  requestTimeoutMs: 30_000
}

/** Build a full deps object with sensible defaults; each test can override. */
export function makeDeps(overrides: Partial<SyncServiceDeps> = {}): SyncServiceDeps {
  const ipc = overrides.ipc ?? makeIpc()
  const { engineFactory } = overrides.engineFactory
    ? { engineFactory: overrides.engineFactory }
    : makeEngine()
  return {
    ipc,
    engineFactory,
    fetch: vi.fn(async () => new Response('{}', { status: 200 })),
    getAuthToken: makeAuthToken(),
    getDevBypassSecret: makeDevBypass(),
    connectivity: makeConnectivity(),
    clock: makeClock(),
    windowEvents: makeWindowEvents(),
    config: baseConfig,
    ...overrides
  }
}

describe('SyncService.start', () => {
  it('kicks an initial sync and transitions not-synced → syncing → synced', async () => {
    const { engineFactory, syncCount } = makeEngine()
    const clock = makeClock()
    const deps = makeDeps({ engineFactory, clock })
    const service = createSyncService(deps)
    const snapshots: string[] = []
    service.onStatusChange((s) => snapshots.push(s.status))

    service.start()
    // Drain microtasks: the initial sync awaits engine.sync().
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(1)
    expect(snapshots).toEqual(['not-synced', 'syncing', 'synced'])
    expect(service.getStatus().status).toBe('synced')
    expect(service.getStatus().lastSyncAt).toBe(clock.now())
  })
})
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: fails — `Cannot find module './service'`.

---

## Task 10: Service factory — `start()` minimal GREEN

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/sync/service.ts`

- [ ] **Step 1: Implement `createSyncService` with just enough to satisfy Task 9**

Create `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/service.ts`:

```ts
import type {
  EngineLike,
  SyncService,
  SyncServiceDeps,
  SyncStatus,
  SyncStatusListener,
  SyncStatusSnapshot
} from './types'
import { makeAdapter } from './adapter'
import { createDebouncer } from './debounce'
import { createEmitter } from './emitter'

export function createSyncService(deps: SyncServiceDeps): SyncService {
  const { ipc, engineFactory, connectivity, clock, windowEvents, config } = deps

  const emitter = createEmitter<SyncStatusSnapshot>()
  const debouncer = createDebouncer(clock, config.debounceMs)
  let engine: EngineLike | null = null
  let status: SyncStatus = 'not-synced'
  let lastSyncAt: number | null = null
  let intervalHandle: ReturnType<typeof clock.setInterval> | null = null
  let connectivityUnsub: (() => void) | null = null
  let focusHandler: EventListener | null = null
  let started = false

  function snapshot(): SyncStatusSnapshot {
    return { status, lastSyncAt }
  }

  function setStatus(next: SyncStatus): void {
    status = next
    emitter.emit(snapshot())
  }

  async function runSync(): Promise<void> {
    if (!engine) return
    if (status === 'syncing') return
    const currentEngine = engine
    setStatus('syncing')
    try {
      await currentEngine.sync()
      if (engine !== currentEngine) return // stop() ran during sync
      lastSyncAt = clock.now()
      setStatus('synced')
    } catch (err) {
      if (engine !== currentEngine) return
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

      // apiFetch is built once and closed over the adapter; the engine
      // factory binds them together. For Task 10 we pass a no-op
      // apiFetch — Task 16 wires the real auth-aware wrapper.
      const adapter = makeAdapter(ipc)
      const apiFetch = async (): Promise<Response> =>
        new Response('{}', { status: 200 })
      engine = engineFactory({ adapter, apiFetch })

      void runSync()
    },

    stop() {
      if (!started) return
      started = false
      debouncer.cancel()
      if (intervalHandle != null) clock.clearInterval(intervalHandle)
      intervalHandle = null
      if (focusHandler) windowEvents.removeEventListener('focus', focusHandler)
      focusHandler = null
      if (connectivityUnsub) connectivityUnsub()
      connectivityUnsub = null
      engine = null
    },

    triggerWrite() {
      if (!started) return
      if (!connectivity.isOnline()) return
      debouncer.trigger(() => {
        void runSync()
      })
    },

    getStatus() {
      return snapshot()
    },

    onStatusChange(listener: SyncStatusListener) {
      const unsub = emitter.on(listener)
      listener(snapshot())
      return unsub
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 1 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 1 test passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.ts \
        apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): service.start kicks initial sync and transitions to synced

Minimal createSyncService factory: emitter + debouncer + engine
construction via injected engineFactory port. apiFetch is a no-op stub
for now (Task 16 wires the real auth-aware wrapper)."
```

---

## Task 11: Service — `start()` idempotent + `stop()` clean teardown

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

- [ ] **Step 1: Add two tests asserting idempotency and listener teardown**

Append inside `service.test.ts` after the existing `describe`:

```ts
describe('SyncService.start idempotency', () => {
  it('second start() is a no-op (engineFactory called once, only one initial sync)', async () => {
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ engineFactory }))

    service.start()
    service.start()
    await new Promise((r) => setTimeout(r, 0))

    expect(engineFactory).toHaveBeenCalledTimes(1)
    expect(syncCount()).toBe(1)
  })
})

describe('SyncService.stop', () => {
  it('removes focus listener, clears interval, and is idempotent', async () => {
    const clock = makeClock()
    const windowEvents = makeWindowEvents()
    const { engineFactory } = makeEngine()
    const service = createSyncService(makeDeps({ clock, windowEvents, engineFactory }))

    service.start()
    await new Promise((r) => setTimeout(r, 0))

    expect(windowEvents.listeners('focus').length).toBe(1)
    expect(clock.pendingTimers()).toBeGreaterThan(0)

    service.stop()
    expect(windowEvents.listeners('focus').length).toBe(0)
    expect(clock.pendingTimers()).toBe(0)

    // Second stop() does not throw
    expect(() => service.stop()).not.toThrow()
  })
})
```

- [ ] **Step 2: Run — expect 1 GREEN (idempotency) + 1 RED (listeners not yet registered)**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: idempotency test passes; the stop() test fails because we have not yet registered focus / interval / connectivity listeners in `start()`.

- [ ] **Step 3: Add focus + interval + connectivity registration to `start()`**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/service.ts`, replace the body of `start()` with:

```ts
    start() {
      if (started) return
      started = true

      const adapter = makeAdapter(ipc)
      const apiFetch = async (): Promise<Response> =>
        new Response('{}', { status: 200 })
      engine = engineFactory({ adapter, apiFetch })

      focusHandler = () => {
        void runSync()
      }
      windowEvents.addEventListener('focus', focusHandler)

      connectivityUnsub = connectivity.subscribe((online) => {
        if (online && status === 'offline') {
          void runSync()
        } else if (!online) {
          setStatus('offline')
        }
      })

      intervalHandle = clock.setInterval(() => {
        if (connectivity.isOnline()) void runSync()
      }, config.intervalMs)

      void runSync()
    },
```

- [ ] **Step 4: Run — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.ts \
        apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): start is idempotent; stop unregisters focus/interval/connectivity"
```

---

## Task 12: Service — `triggerWrite()` debounce + gating

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

- [ ] **Step 1: Add three tests covering debounce, no-op-before-start, and no-op-when-offline**

Append:

```ts
describe('SyncService.triggerWrite', () => {
  it('debounces multiple calls within config.debounceMs into a single sync', async () => {
    const clock = makeClock()
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, engineFactory }))

    service.start()
    await new Promise((r) => setTimeout(r, 0)) // let initial sync settle
    expect(syncCount()).toBe(1)

    service.triggerWrite()
    service.triggerWrite()
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs - 1)
    expect(syncCount()).toBe(1)

    clock.tick(1)
    await new Promise((r) => setTimeout(r, 0))
    expect(syncCount()).toBe(2)
  })

  it('is a no-op before start()', async () => {
    const clock = makeClock()
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ clock, engineFactory }))

    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(0)
  })

  it('is a no-op when connectivity reports offline', async () => {
    const clock = makeClock()
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(
      makeDeps({ clock, connectivity, engineFactory })
    )

    service.start()
    await new Promise((r) => setTimeout(r, 0))
    const baseline = syncCount() // 1 from initial sync

    connectivity.setOnline(false)
    service.triggerWrite()
    clock.tick(baseConfig.debounceMs * 2)
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(baseline)
  })
})
```

- [ ] **Step 2: Run — expect 6 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 6 tests pass (the implementation already short-circuits on `started === false` and `!connectivity.isOnline()`).

- [ ] **Step 3: Commit (test-only)**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): triggerWrite debounces, no-ops before start, no-ops when offline"
```

---

## Task 13: Service — connectivity transitions

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

- [ ] **Step 1: Add two tests covering offline transition + online recovery**

Append:

```ts
describe('SyncService connectivity transitions', () => {
  it('offline transition sets status to offline immediately (no engine call)', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => setTimeout(r, 0))
    expect(service.getStatus().status).toBe('synced')
    const baseline = syncCount()

    connectivity.setOnline(false)

    expect(service.getStatus().status).toBe('offline')
    expect(syncCount()).toBe(baseline) // no new engine call
  })

  it('online recovery from offline kicks a sync', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory, syncCount } = makeEngine()
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))
    const snapshots: string[] = []
    service.onStatusChange((s) => snapshots.push(s.status))

    service.start()
    await new Promise((r) => setTimeout(r, 0))
    connectivity.setOnline(false)
    expect(service.getStatus().status).toBe('offline')

    connectivity.setOnline(true)
    await new Promise((r) => setTimeout(r, 0))

    expect(syncCount()).toBe(2) // initial + online-recovery
    expect(snapshots).toContain('offline')
    expect(snapshots[snapshots.length - 1]).toBe('synced')
  })
})
```

- [ ] **Step 2: Run — expect 8 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 8 tests pass.

- [ ] **Step 3: Commit (test-only)**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): offline flips status; online recovery kicks a sync"
```

---

## Task 14: Service — engine error classification + AUTH_EXPIRED dispatch

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

- [ ] **Step 1: Add three tests covering error / offline / AUTH_EXPIRED paths**

Append:

```ts
describe('SyncService error classification', () => {
  it('engine error with connectivity online classifies as error', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        throw new Error('boom')
      }
    })
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => setTimeout(r, 0))

    expect(service.getStatus().status).toBe('error')
  })

  it('engine error with connectivity offline classifies as offline', async () => {
    const connectivity = makeConnectivity({ initialOnline: true })
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        connectivity.setOnline(false) // model: network died mid-flight
        throw new Error('network down')
      }
    })
    const service = createSyncService(makeDeps({ connectivity, engineFactory }))

    service.start()
    await new Promise((r) => setTimeout(r, 0))

    expect(service.getStatus().status).toBe('offline')
  })

  it('AUTH_EXPIRED dispatches sync-auth-expired event and sets status to error', async () => {
    const windowEvents = makeWindowEvents()
    const { engineFactory } = makeEngine({
      syncImpl: async () => {
        throw new Error('AUTH_EXPIRED')
      }
    })
    const service = createSyncService(makeDeps({ windowEvents, engineFactory }))

    const dispatched: Event[] = []
    windowEvents.addEventListener('sync-auth-expired', (e) => dispatched.push(e))

    service.start()
    await new Promise((r) => setTimeout(r, 0))

    expect(dispatched).toHaveLength(1)
    expect(dispatched[0].type).toBe('sync-auth-expired')
    expect(service.getStatus().status).toBe('error')
  })
})
```

- [ ] **Step 2: Run — expect 11 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 11 tests pass.

- [ ] **Step 3: Commit (test-only)**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): engine errors classify as error/offline; AUTH_EXPIRED dispatches event"
```

---

## Task 15: Service — `onStatusChange` immediate delivery + post-stop suppression

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`

- [ ] **Step 1: Add two tests covering subscribe-time delivery and stop-suppression**

Append:

```ts
describe('SyncService.onStatusChange', () => {
  it('invokes the listener immediately on subscribe and again on every transition; unsubscribe stops delivery', async () => {
    const { engineFactory } = makeEngine()
    const service = createSyncService(makeDeps({ engineFactory }))
    const calls: string[] = []
    const unsub = service.onStatusChange((s) => calls.push(s.status))

    expect(calls).toEqual(['not-synced']) // immediate

    service.start()
    await new Promise((r) => setTimeout(r, 0))
    expect(calls).toEqual(['not-synced', 'syncing', 'synced'])

    unsub()
    service.stop()
    service.start() // restart should fire more events but listener should be gone
    await new Promise((r) => setTimeout(r, 0))
    expect(calls).toEqual(['not-synced', 'syncing', 'synced']) // unchanged
  })

  it('suppresses status updates after stop() even if a sync is mid-flight', async () => {
    let resolveSync: () => void = () => {}
    const blocker = new Promise<void>((r) => {
      resolveSync = r
    })
    const { engineFactory } = makeEngine({ syncImpl: () => blocker })
    const service = createSyncService(makeDeps({ engineFactory }))
    const calls: string[] = []
    service.onStatusChange((s) => calls.push(s.status))

    service.start() // status → syncing, awaits engine.sync
    await new Promise((r) => setTimeout(r, 0))
    expect(calls).toContain('syncing')
    expect(calls).not.toContain('synced')

    service.stop()
    resolveSync()
    await new Promise((r) => setTimeout(r, 0))

    // No 'synced' or 'error' snapshot should have been emitted after stop()
    expect(calls).not.toContain('synced')
    expect(calls).not.toContain('error')
  })
})
```

- [ ] **Step 2: Run — expect 13 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 13 tests pass.

- [ ] **Step 3: Commit (test-only)**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "test(sync): onStatusChange fires immediately and on transitions; stop suppresses in-flight updates"
```

---

## Task 16: Service — auth-aware apiFetch (401 retry with fresh token)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/service.ts`

Per the spec, the auth-aware apiFetch wrapper lives *inside* the service and the engine factory closes over it. The Task 10 stub is replaced now.

- [ ] **Step 1: Add a test asserting the engine's apiFetch parameter behaves correctly**

Append to `service.test.ts`:

```ts
describe('SyncService apiFetch (passed into engineFactory)', () => {
  it('builds an apiFetch that retries 401 once with a fresh bearer token', async () => {
    // We intercept the apiFetch by capturing the value passed to engineFactory.
    let capturedApiFetch:
      | ((path: string, init?: RequestInit) => Promise<Response>)
      | null = null
    const engineFactory: EngineFactory = (cfg) => {
      capturedApiFetch = cfg.apiFetch
      return { sync: async () => {} }
    }

    let tokenCalls = 0
    const tokens = ['stale-token', 'fresh-token']
    const getAuthToken = vi.fn(async () => tokens[tokenCalls++] ?? 'fresh-token')

    const fetch = vi.fn(async (_url: string, init?: RequestInit) => {
      const headers = (init?.headers ?? {}) as Record<string, string>
      const auth = headers['Authorization']
      if (auth === 'Bearer stale-token') return new Response('', { status: 401 })
      return new Response('{"ok":true}', { status: 200 })
    })

    const service = createSyncService(
      makeDeps({ engineFactory, getAuthToken, fetch })
    )
    service.start()

    expect(capturedApiFetch).not.toBeNull()
    const res = await capturedApiFetch!('/sync/push', { method: 'POST' })

    expect(res.status).toBe(200)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(getAuthToken).toHaveBeenCalledTimes(2)
  })

  it('falls back to X-Dev-Bypass header when no auth token is available', async () => {
    let capturedApiFetch:
      | ((path: string, init?: RequestInit) => Promise<Response>)
      | null = null
    const engineFactory: EngineFactory = (cfg) => {
      capturedApiFetch = cfg.apiFetch
      return { sync: async () => {} }
    }

    const fetch = vi.fn(
      async (_url: string, init?: RequestInit) =>
        new Response(
          JSON.stringify({ headers: init?.headers }),
          { status: 200 }
        )
    )

    const service = createSyncService(
      makeDeps({
        engineFactory,
        getAuthToken: makeAuthToken(null),
        getDevBypassSecret: makeDevBypass('s3cret'),
        fetch
      })
    )
    service.start()

    await capturedApiFetch!('/sync/pull')
    const sentHeaders = fetch.mock.calls[0][1]?.headers as Record<string, string>
    expect(sentHeaders['X-Dev-Bypass']).toBe('s3cret')
    expect(sentHeaders['Authorization']).toBeUndefined()
  })
})
```

- [ ] **Step 2: Run — expect 2 RED** (the stub apiFetch ignores deps.fetch / deps.getAuthToken)

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 2 new tests fail.

- [ ] **Step 3: Implement the real apiFetch in `service.ts`**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/service.ts`, add this helper above `createSyncService`:

```ts
interface ApiFetchDeps {
  fetch: SyncServiceDeps['fetch']
  getAuthToken: SyncServiceDeps['getAuthToken']
  getDevBypassSecret: SyncServiceDeps['getDevBypassSecret']
  workerUrl: string
  requestTimeoutMs: number
}

function createApiFetch(deps: ApiFetchDeps): (
  path: string,
  init?: RequestInit
) => Promise<Response> {
  async function makeRequest(token: string | null, init?: RequestInit): Promise<Response> {
    const headers: Record<string, string> = {
      ...(init?.headers as Record<string, string>),
      'Content-Type': 'application/json'
    }
    if (token) {
      headers['Authorization'] = `Bearer ${token}`
    } else {
      const secret = await deps.getDevBypassSecret()
      if (secret) headers['X-Dev-Bypass'] = secret
      else
        return new Response(JSON.stringify({ error: 'Not authenticated' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' }
        })
    }
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), deps.requestTimeoutMs)
    if (init?.signal) {
      init.signal.addEventListener('abort', () => controller.abort(), { once: true })
    }
    try {
      return await deps.fetch(`${deps.workerUrl}${arguments[1]?.path ?? ''}`, {
        ...init,
        headers,
        signal: controller.signal
      })
    } finally {
      clearTimeout(timeout)
    }
  }

  return async function apiFetch(path: string, init?: RequestInit): Promise<Response> {
    const initWithPath = { ...init }
    const token = await deps.getAuthToken()
    // Inline first-call URL composition (avoids the arguments hack above):
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), deps.requestTimeoutMs)
    if (init?.signal) {
      init.signal.addEventListener('abort', () => controller.abort(), { once: true })
    }
    try {
      const headers: Record<string, string> = {
        ...((init?.headers as Record<string, string>) ?? {}),
        'Content-Type': 'application/json'
      }
      if (token) headers['Authorization'] = `Bearer ${token}`
      else {
        const secret = await deps.getDevBypassSecret()
        if (secret) headers['X-Dev-Bypass'] = secret
        else
          return new Response(JSON.stringify({ error: 'Not authenticated' }), {
            status: 401,
            headers: { 'Content-Type': 'application/json' }
          })
      }

      let response = await deps.fetch(`${deps.workerUrl}${path}`, {
        ...initWithPath,
        headers,
        signal: controller.signal
      })

      // Retry once on 401 with a freshly-minted token.
      if (response.status === 401 && token) {
        const freshToken = await deps.getAuthToken()
        if (freshToken && freshToken !== token) {
          const retryHeaders = { ...headers, Authorization: `Bearer ${freshToken}` }
          response = await deps.fetch(`${deps.workerUrl}${path}`, {
            ...initWithPath,
            headers: retryHeaders,
            signal: controller.signal
          })
        }
      }
      return response
    } finally {
      clearTimeout(timeout)
    }
  }
}
```

Then in the `start()` body, replace the stub:

```ts
      const apiFetch = async (): Promise<Response> =>
        new Response('{}', { status: 200 })
```

with:

```ts
      const apiFetch = createApiFetch({
        fetch: deps.fetch,
        getAuthToken: deps.getAuthToken,
        getDevBypassSecret: deps.getDevBypassSecret,
        workerUrl: config.workerUrl,
        requestTimeoutMs: config.requestTimeoutMs
      })
```

(Delete the unused `makeRequest` helper inside `createApiFetch` — the inline version above is the real implementation. Keep only one function inside `createApiFetch`.)

- [ ] **Step 4: Run — expect 15 GREEN**

```bash
pnpm vitest run src/renderer/src/services/sync/service.test.ts
```

Expected: 15 tests pass.

- [ ] **Step 5: Verify typecheck passes**

```bash
pnpm typecheck
```

Expected: passes.

- [ ] **Step 6: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/service.ts \
        apps/rishi-electron/src/renderer/src/services/sync/service.test.ts
git commit -m "feat(sync): auth-aware apiFetch with 401 retry and dev-bypass fallback

Replaces the Task 10 no-op stub. createApiFetch builds the wrapper from
the fetch / getAuthToken / getDevBypassSecret / workerUrl /
requestTimeoutMs ports. Mirrors the legacy sync-triggers.ts behavior:
30s AbortController timeout, retry once on 401 with a freshly-minted
token, fall back to X-Dev-Bypass header when no bearer token."
```

---

## Task 17: Public exports (`index.ts`)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/sync/index.ts`

- [ ] **Step 1: Replace the placeholder with re-exports of the public surface only**

Replace the contents of `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/sync/index.ts`:

```ts
export { createSyncService } from './service'
export type {
  ClockPort,
  ConnectivityPort,
  EngineFactory,
  EngineFactoryConfig,
  EngineLike,
  SyncConfig,
  SyncIpcChannels,
  SyncService,
  SyncServiceDeps,
  SyncStatus,
  SyncStatusListener,
  SyncStatusSnapshot,
  WindowEventsPort
} from './types'
```

Do **not** export `makeAdapter`, `createDebouncer`, or `createEmitter` — those are internals.

- [ ] **Step 2: Verify typecheck still passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Sanity-grep that internals are NOT re-exported**

```bash
cd /tmp/rishi-sync-refactor
grep -nE "makeAdapter|createDebouncer|createEmitter" \
  apps/rishi-electron/src/renderer/src/services/sync/index.ts
```

Expected: no matches.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/sync/index.ts
git commit -m "refactor(sync): export only the public surface (createSyncService + types)"
```

---

## Task 18: Wire `getSyncService` in `services/index.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts`

- [ ] **Step 1: Add the lazy `getSyncService()` singleton alongside `getRagService` / `getTtsService`**

Replace the contents of `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/services/index.ts` with:

```ts
import { createRagService, type RagService } from './rag'
import { createTtsService, type AuthHeader, type TtsService } from './tts'
import {
  createSyncService,
  type ConnectivityPort,
  type SyncService
} from './sync'
import { createSyncEngine } from '@rishi/shared/sync-engine'
import { connectivityActor, isOnline } from '@/modules/connectivity'
import { embedSingleText } from '@/modules/embed-fallback'
import { getAuthToken } from '@/modules/auth'
import config from '@/config.json'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook
      },
      embed: embedSingleText
    })
  }
  return _rag
}

let _tts: TtsService | null = null

async function resolveTtsAuth(): Promise<AuthHeader> {
  const token = await getAuthToken()
  if (token) return { kind: 'bearer', token }
  const devBypassSecret = await window.electron.getDevBypassSecret()
  if (devBypassSecret) return { kind: 'dev-bypass', secret: devBypassSecret }
  throw new Error('Not authenticated -- sign in to use text-to-speech')
}

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
  }
  return _tts
}

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
        removeEventListener: (type, listener) =>
          window.removeEventListener(type, listener),
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

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If any `window.electron.sync*` method is reported missing on the typed surface, check `apps/rishi-electron/src/preload/types.ts` — all 17 IPC methods must already exist (they back the current `sync-adapter.ts`).

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(sync): wire production getSyncService singleton

Composes window.electron.sync* (ipc), createSyncEngine from
@rishi/shared/sync-engine (engineFactory), globalThis.fetch (transport),
@/modules/auth (getAuthToken), window.electron.getDevBypassSecret
(getDevBypassSecret), @/modules/connectivity (adapted into a port with
subscribe), the global timer functions (clock), window (windowEvents),
and literal config knobs (workerUrl, 5min interval, 2s debounce, 30s
timeout)."
```

---

## Task 19: Migrate `__root.tsx`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/routes/__root.tsx`

- [ ] **Step 1: Replace the import + useEffect lifecycle**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/routes/__root.tsx`, replace:

```ts
import { initDesktopSync, destroyDesktopSync } from '@/modules/sync-triggers'
```

with:

```ts
import { getSyncService } from '@/services'
```

Then replace the existing effect:

```tsx
  useEffect(() => {
    initDesktopSync()
    return () => {
      destroyDesktopSync()
    }
  }, [])
```

with:

```tsx
  useEffect(() => {
    const sync = getSyncService()
    sync.start()
    return () => {
      sync.stop()
    }
  }, [])
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/routes/__root.tsx
git commit -m "refactor(sync): migrate __root.tsx to getSyncService().start/stop"
```

---

## Task 20: Migrate `NoteEditor`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/highlights/NoteEditor.tsx`

- [ ] **Step 1: Replace the import + call site**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/components/highlights/NoteEditor.tsx`, replace:

```ts
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
```

with:

```ts
import { getSyncService } from '@/services'
```

Replace the single call in `handleSave`:

```ts
    triggerSyncOnWrite()
```

with:

```ts
    getSyncService().triggerWrite()
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/components/highlights/NoteEditor.tsx
git commit -m "refactor(sync): migrate NoteEditor to getSyncService().triggerWrite"
```

---

## Task 21: Migrate `HighlightsPanel`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/highlights/HighlightsPanel.tsx`

- [ ] **Step 1: Replace the import + call site**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/components/highlights/HighlightsPanel.tsx`, replace:

```ts
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
```

with:

```ts
import { getSyncService } from '@/services'
```

Replace the single call in `handleDelete`:

```ts
      triggerSyncOnWrite()
```

with:

```ts
      getSyncService().triggerWrite()
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/components/highlights/HighlightsPanel.tsx
git commit -m "refactor(sync): migrate HighlightsPanel to getSyncService().triggerWrite"
```

---

## Task 22: Migrate `EpubView`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`

`EpubView` calls `triggerSyncOnWrite()` from two places: the highlight save handler (around line 219) and the `locationChanged` handler (around line 577).

- [ ] **Step 1: Replace the import**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx`, replace:

```ts
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
```

with:

```ts
import { getSyncService } from '@/services'
```

- [ ] **Step 2: Update the two call sites**

Replace (in `handleHighlightColor`):

```ts
        .then(() => triggerSyncOnWrite())
```

with:

```ts
        .then(() => getSyncService().triggerWrite())
```

Replace (in `locationChanged`):

```ts
              triggerSyncOnWrite()
```

with:

```ts
              getSyncService().triggerWrite()
```

- [ ] **Step 3: Sanity-grep that no `triggerSyncOnWrite` remains in the file**

```bash
cd /tmp/rishi-sync-refactor
grep -n "triggerSyncOnWrite" \
  apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx
```

Expected: no matches.

- [ ] **Step 4: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/components/epub/EpubView.tsx
git commit -m "refactor(sync): migrate EpubView (highlight save + locationChanged) to getSyncService"
```

---

## Task 23: Migrate `useChat`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/hooks/useChat.ts`

The chatStore WIP that landed in PR #9 modified `useChat` lightly; verify the `triggerSyncOnWrite` call site still exists at the end of `sendMessage` (around line 210) before editing.

- [ ] **Step 1: Sanity-grep the file**

```bash
cd /tmp/rishi-sync-refactor
grep -n "triggerSyncOnWrite\|sync-triggers" \
  apps/rishi-electron/src/renderer/src/hooks/useChat.ts
```

Expected: 2 matches — one import line, one call line. If different, read the file and adapt the edit accordingly.

- [ ] **Step 2: Replace the import + call site**

In `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/hooks/useChat.ts`, replace:

```ts
import { triggerSyncOnWrite } from '@/modules/sync-triggers'
```

with:

```ts
import { getSyncService } from '@/services'
```

Replace:

```ts
        triggerSyncOnWrite()
```

with:

```ts
        getSyncService().triggerWrite()
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/hooks/useChat.ts
git commit -m "refactor(sync): migrate useChat to getSyncService().triggerWrite"
```

---

## Task 24: Migrate `SyncStatusIndicator` (snapshot-shaped state)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/components/SyncStatusIndicator.tsx`

Today's component holds `status: string`. The new service emits a `SyncStatusSnapshot`. We update local state to the snapshot shape and label off `snapshot.status`.

- [ ] **Step 1: Replace the file contents**

Replace the contents of `/tmp/rishi-sync-refactor/apps/rishi-electron/src/renderer/src/components/SyncStatusIndicator.tsx`:

```tsx
import { useEffect, useState } from 'react'
import { getSyncService, type SyncStatusSnapshot } from '@/services'

export function SyncStatusIndicator() {
  const [snapshot, setSnapshot] = useState<SyncStatusSnapshot>(() =>
    getSyncService().getStatus()
  )

  useEffect(() => getSyncService().onStatusChange(setSnapshot), [])

  if (snapshot.status === 'synced' || snapshot.status === 'not-synced') return null

  const labels: Record<string, { text: string; color: string }> = {
    syncing: { text: 'Syncing...', color: 'text-blue-500' },
    error: { text: 'Sync error', color: 'text-red-500' },
    offline: { text: 'Offline', color: 'text-gray-400' }
  }

  const label = labels[snapshot.status]
  if (!label) return null

  return (
    <div className={`text-xs ${label.color} flex items-center gap-1`}>
      {snapshot.status === 'syncing' && (
        <span className="animate-spin inline-block w-3 h-3 border border-current border-t-transparent rounded-full" />
      )}
      {label.text}
    </div>
  )
}
```

- [ ] **Step 2: Re-export `SyncStatusSnapshot` from `services/index.ts`**

Confirm `services/index.ts` re-exports `SyncStatusSnapshot` (the import above relies on `@/services`). The current Task-18 wiring re-exports the type indirectly via `from './sync'`, but `services/index.ts` itself only re-exports a few aliases. To make `SyncStatusSnapshot` reachable from `@/services`, append to `services/index.ts`:

```ts
export type { SyncStatusSnapshot, SyncStatus } from './sync'
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
cd /tmp/rishi-sync-refactor
git add apps/rishi-electron/src/renderer/src/components/SyncStatusIndicator.tsx \
        apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "refactor(sync): migrate SyncStatusIndicator to snapshot-shaped state

Local state is now the SyncStatusSnapshot record (status + lastSyncAt)
instead of a bare string. onStatusChange invokes the setter immediately
on subscribe (matches the legacy behavior the indicator depends on)."
```

---

## Task 25: Delete legacy modules + tests

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/sync-triggers.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/sync-adapter.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/sync-adapter.test.ts`

- [ ] **Step 1: Confirm no remaining imports of the old names**

```bash
cd /tmp/rishi-sync-refactor
git grep -nE "from '@/modules/sync-triggers'|from '@/modules/sync-adapter'|from '\\./sync-triggers'|from '\\./sync-adapter'" \
  apps/rishi-electron/src/renderer/src
```

Expected: only matches inside the four files we're about to delete (`sync-triggers.ts` imports from `./sync-adapter`; their `.test.ts` files import from `./sync-triggers` and `./sync-adapter`). No imports anywhere else.

If any external caller still imports any of the old paths, return to the relevant migration task (19–24) and complete it before continuing.

- [ ] **Step 2: Delete the 4 files**

```bash
cd /tmp/rishi-sync-refactor
git rm apps/rishi-electron/src/renderer/src/modules/sync-triggers.ts \
       apps/rishi-electron/src/renderer/src/modules/sync-triggers.test.ts \
       apps/rishi-electron/src/renderer/src/modules/sync-adapter.ts \
       apps/rishi-electron/src/renderer/src/modules/sync-adapter.test.ts
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Run the sync service test suite**

```bash
pnpm vitest run src/renderer/src/services/sync/
```

Expected: all sync service tests pass (emitter 3, adapter 4, debounce 3, service 15 = 25 total).

- [ ] **Step 5: Commit**

```bash
cd /tmp/rishi-sync-refactor
git commit -m "refactor(sync): delete legacy sync-triggers/sync-adapter modules + tests

4 files removed (2 modules, 2 tests). Per meta-spec's no-shims rule:
one PR, one source of truth. All sync surfaces flow through
getSyncService()."
```

---

## Task 26: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and the full test suite**

```bash
cd /tmp/rishi-sync-refactor/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm vitest run
```

Expected: all three pass *for the sync-touched surface*. The following pre-existing failures are out of scope:
- `src/main/**` typecheck errors (sqlite/electron typing drift)
- `stores/navStore.test.ts` typecheck error (unrelated)
- `queries.outline*` runtime test failures from a better-sqlite3 native binding mismatch in the worktree

If a *new* failure appears that is clearly caused by sync changes (any test file under `services/sync/`, or any of the six migrated callers), fix it in a follow-up commit (`fix(sync): ...`) before opening the PR.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
cd /tmp/rishi-sync-refactor
grep -rn "createSyncService" apps/rishi-electron/src/
```

Expected: matches only in `services/sync/service.ts` (definition), `services/sync/index.ts` (re-export), `services/index.ts` (wiring), and `services/sync/service.test.ts` (test usage). No other call sites.

- [ ] **Step 3: Sanity-check internals are not externally imported**

```bash
cd /tmp/rishi-sync-refactor
grep -rnE "from '@/services/sync/adapter'|from '@/services/sync/debounce'|from '@/services/sync/emitter'|from '@/services/sync/service'|from '@/services/sync/types'" \
  apps/rishi-electron/src/
```

Expected: no matches outside `apps/rishi-electron/src/renderer/src/services/sync/`.

- [ ] **Step 4: Push the branch and open the PR**

```bash
cd /tmp/rishi-sync-refactor
git push -u origin refactor/sync-service
gh pr create --title "refactor(sync): collapse sync-triggers + sync-adapter into services/sync deep module" --body "$(cat <<'EOF'
## Summary
- New \`SyncService\` at \`apps/rishi-electron/src/renderer/src/services/sync/\` collapses \`modules/sync-triggers.ts\` (module-scoped engine + 4 event handler refs + listener Set + debounce timer + apiFetch + direct \`navigator.onLine\` reads) and \`modules/sync-adapter.ts\` (class-based \`SyncDbAdapter\`) behind a typed factory boundary.
- 9 ports injected at the wiring site: \`ipc\`, \`engineFactory\`, \`fetch\`, \`getAuthToken\`, \`getDevBypassSecret\`, \`connectivity\`, \`clock\`, \`windowEvents\`, \`config\`. The shared \`@rishi/shared/sync-engine\` is consumed via \`engineFactory\` — service has no compile-time dependency on it.
- Public surface is 5 methods: \`start\`, \`stop\`, \`triggerWrite\`, \`getStatus\`, \`onStatusChange\` (returns unsubscribe). Status is a discriminated \`SyncStatusSnapshot\` (status + lastSyncAt).
- Callers migrated: \`__root.tsx\` (lifecycle), \`NoteEditor\`, \`HighlightsPanel\`, \`EpubView\` (2 sites), \`useChat\`, \`SyncStatusIndicator\` (snapshot shape).
- 4 legacy files deleted (2 modules + 2 tests). No shims.
- TDD throughout: red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-sync-service-design.md\`
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 1, service 4 of 6)

## Test plan
- [ ] \`pnpm typecheck\` clean for the sync surface (pre-existing \`src/main/**\` and \`navStore.test.ts\` errors are out of scope)
- [ ] \`pnpm lint\` clean
- [ ] \`pnpm vitest run src/renderer/src/services/sync/\` — emitter (3), adapter (4), debounce (3), service (15) = 25 new boundary tests pass
- [ ] Manual: open the app, observe initial sync runs and indicator transitions \`syncing → synced\`
- [ ] Manual: pull network cable, observe indicator flips to \`offline\`; restore cable, observe sync kicks and returns to \`synced\`
- [ ] Manual: edit a highlight note, observe a sync fires ~2s after the last keystroke (debounce)
- [ ] Manual: leave the app idle, observe a sync fires after 5 minutes (interval)
- [ ] Manual: focus the window after backgrounding it, observe a sync fires
- [ ] Manual: in dev with \`X-Dev-Bypass\` secret configured, sign out and observe the dev-bypass header path still works
EOF
)"
```

---

## Summary

After all tasks complete:
- **~26 commits** on the `refactor/sync-service` branch in the `/tmp/rishi-sync-refactor` worktree.
- **25 new boundary tests** across `services/sync/{emitter,adapter,debounce,service}.test.ts` — all using hand-rolled adapter helpers (`makeIpc`, `makeEngine`, `makeConnectivity`, `makeAuthToken`, `makeDevBypass`, `makeClock`, `makeWindowEvents`, `makeDeps`), no `vi.mock`, no `vi.resetModules`.
- **Net diff (approximate):** +650 lines added (service + tests + types + emitter + adapter + debouncer + wiring), −400 lines removed (legacy triggers + adapter + their 2 test files). Slightly positive.
- **No internals exported.** The public surface from `services/sync/index.ts` is `createSyncService` + the 11 public types. Adapter, debounce, emitter stay strictly internal.
- **Connectivity is a port.** The renderer's `connectivityActor` is adapted into a `ConnectivityPort` at the wiring site; the service no longer reads `navigator.onLine` directly. When the Connectivity service refactor ships its `getConnectivityService()`, the Sync wiring site swaps a single import.
- **Clock is a port.** The debounce + interval logic is fully deterministic in tests via the in-memory `makeClock()`.
- **WindowEvents is a port.** `'focus'` listeners and the `'sync-auth-expired'` `CustomEvent` dispatch flow through it; tests assert listener registration / removal without any DOM polyfill.
- All 12 boundary scenarios from the spec's Test Strategy are covered across the 25 tests (start happy path, start idempotent, stop teardown + idempotent, debounce coalescing, no-op-before-start, no-op-when-offline, online recovery, offline transition, error classification on engine fail, AUTH_EXPIRED dispatch, immediate subscribe + transitions, post-stop suppression — plus the auth-aware apiFetch wrapper's 401-retry and dev-bypass fallback).
