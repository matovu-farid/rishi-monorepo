/**
 * NetInfo → xstate adapter implementing the shared `ConnectivityPort`
 * interface (`@rishi/shared/sync/types.ConnectivityPort` /
 * `@rishi/shared/connectivity/types.ConnectivityService`).
 *
 * Wraps `connectivityMachine` and feeds it ONLINE/OFFLINE events from
 * `@react-native-community/netinfo`. The public methods (`isOnline`,
 * `subscribe`, `start`, `stop`) match the shape electron's
 * `ConnectivityService` exposes, so future shared sync code that depends
 * on the port can construct one on mobile and use it identically.
 *
 * Behavioural choices:
 *   - `isConnected === false` → OFFLINE
 *   - `isConnected === true`  → ONLINE
 *   - `isConnected === null`  → IGNORED (transitional state during boot)
 *   - `start()` and `stop()` are both idempotent
 *   - `subscribe(listener)` fires on transitions only (edge-detected
 *     against the xstate state value)
 */
import NetInfo from '@react-native-community/netinfo'
import { createActor, type Actor } from 'xstate'
import type { ConnectivityService } from '@rishi/shared/connectivity/types'
import { connectivityMachine } from '@/lib/machines/connectivityMachine'

type Unsubscribe = () => void

export function createMobileConnectivityPort(): ConnectivityService {
  let actor: Actor<typeof connectivityMachine> | null = null
  let unsubNetInfo: Unsubscribe | null = null
  const listeners = new Set<(online: boolean) => void>()
  let lastValue: 'online' | 'offline' = 'online'

  function ensureActor(): Actor<typeof connectivityMachine> {
    if (actor == null) {
      actor = createActor(connectivityMachine)
      actor.start()
      lastValue = actor.getSnapshot().value as 'online' | 'offline'
      actor.subscribe((snapshot) => {
        const next = snapshot.value as 'online' | 'offline'
        if (next !== lastValue) {
          lastValue = next
          for (const l of listeners) l(next === 'online')
        }
      })
    }
    return actor
  }

  return {
    isOnline() {
      return lastValue === 'online'
    },

    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },

    start() {
      ensureActor()
      if (unsubNetInfo != null) return // idempotent
      unsubNetInfo = NetInfo.addEventListener((state) => {
        if (state.isConnected === false) {
          actor?.send({ type: 'OFFLINE' })
        } else if (state.isConnected === true) {
          actor?.send({ type: 'ONLINE' })
        }
        // null → ignore (transitional)
      })
    },

    stop() {
      if (unsubNetInfo != null) {
        unsubNetInfo()
        unsubNetInfo = null
      }
      if (actor != null) {
        actor.stop()
        actor = null
      }
      // Reset to default so the next start() begins from 'online'.
      lastValue = 'online'
    },
  }
}
