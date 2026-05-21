/**
 * Mobile connectivityMachine — ported from
 * `apps/rishi-electron/src/renderer/src/machines/connectivityMachine.ts`.
 *
 * Identical state shape and events to electron. The only behavioural
 * difference is the *initial* state: electron derives it from
 * `navigator.onLine`, which doesn't exist on RN. We default to `online`
 * and let the `MobileConnectivityPort` (in `lib/connectivity/`) feed real
 * ONLINE / OFFLINE events from NetInfo on subscribe.
 */
import { setup } from 'xstate'

export type ConnectivityEvent = { type: 'ONLINE' } | { type: 'OFFLINE' }

export const connectivityMachine = setup({
  types: {
    events: {} as ConnectivityEvent,
  },
}).createMachine({
  id: 'connectivity',
  initial: 'online',
  states: {
    online: { on: { OFFLINE: 'offline' } },
    offline: { on: { ONLINE: 'online' } },
  },
})
