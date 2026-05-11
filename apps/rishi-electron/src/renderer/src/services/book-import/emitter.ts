/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 *
 * Duplicated from services/tts/emitter.ts and services/sync/emitter.ts per
 * the spec's Open Question 4 (services should not depend on each other's
 * internals). If a fourth service wants the same primitive, lift to
 * services/_shared/emitter.ts.
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
