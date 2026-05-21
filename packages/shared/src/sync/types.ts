import type { SyncDbAdapter } from '../sync-adapter'

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
