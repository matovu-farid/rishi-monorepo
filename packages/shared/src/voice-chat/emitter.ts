/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 *
 * Verbatim port from
 * `apps/rishi-electron/src/renderer/src/services/voice-chat/emitter.ts`.
 * Kept duplicated from `tts/emitter.ts` per the original electron-side
 * decision (services should not depend on each other's internals).
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
