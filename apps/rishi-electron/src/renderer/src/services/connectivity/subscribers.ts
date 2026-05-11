import type { ConnectivityListener } from './types'

/**
 * Tiny observer set typed to ConnectivityListener (boolean payload). Mirrors
 * services/tts/emitter.ts + services/sync/emitter.ts but narrowed to the
 * single boolean signal Connectivity emits. Duplicated deliberately so
 * services stay independent (meta-spec rule).
 *
 * Internal — not exported from services/connectivity/index.ts.
 */
export interface Subscribers {
  add(listener: ConnectivityListener): void
  remove(listener: ConnectivityListener): void
  notify(online: boolean): void
}

export function createSubscribers(): Subscribers {
  const listeners = new Set<ConnectivityListener>()
  return {
    add(listener) {
      listeners.add(listener)
    },
    remove(listener) {
      listeners.delete(listener)
    },
    notify(online) {
      for (const listener of listeners) listener(online)
    }
  }
}
