/**
 * Tiny typed emitter — no event names, single payload type T.
 *
 * Lifted into shared (electron's services/book-import/emitter.ts had three
 * near-identical copies). Duplication tradeoff resolved: shared owns one.
 */
import type { EmitterPort } from "./types";

export function createEmitter<T>(): EmitterPort<T> {
  const listeners = new Set<(payload: T) => void>();
  return {
    emit(payload) {
      for (const listener of listeners) listener(payload);
    },
    on(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
