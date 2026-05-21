export type ConnectivityListener = (online: boolean) => void

/**
 * The minimal browser-event surface the service needs. `window` satisfies this
 * shape natively in production; tests inject a hand-rolled fake.
 */
export interface ConnectivitySource {
  readonly onLine: boolean
  addEventListener(type: 'online' | 'offline', listener: () => void): void
  removeEventListener(type: 'online' | 'offline', listener: () => void): void
}

export interface ConnectivityServiceDeps {
  source: ConnectivitySource
}

/**
 * Public interface. Shape-compatible with `services/sync/types.ConnectivityPort`
 * — `isOnline()` + `subscribe()` overlap exactly, so a `ConnectivityService`
 * passes structural typing for `ConnectivityPort` (extra `start`/`stop` are
 * ignored by Sync).
 */
export interface ConnectivityService {
  /** Synchronous: is the renderer currently online? */
  isOnline(): boolean
  /**
   * Subscribe to online/offline transitions. Listener fires only on transitions
   * (edge-detected against the underlying xstate state value). Callers needing
   * the current value at subscribe time should call `isOnline()` separately.
   * Returns an unsubscribe function.
   */
  subscribe(listener: ConnectivityListener): () => void
  /**
   * Start the service: create the xstate actor (if not yet built), start it,
   * register `source.addEventListener('online' | 'offline', …)` handlers.
   * Idempotent — calling `start()` twice is a no-op.
   */
  start(): void
  /**
   * Stop the service: remove source listeners, stop the xstate actor, drop the
   * actor reference. After `stop()`, `isOnline()` returns the last known value
   * but no further transitions are observed until `start()` is called again.
   * Idempotent.
   */
  stop(): void
}
