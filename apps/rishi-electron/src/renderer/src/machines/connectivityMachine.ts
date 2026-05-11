import { setup } from 'xstate'

export type ConnectivityEvent = { type: 'ONLINE' } | { type: 'OFFLINE' }

export const connectivityMachine = setup({
  types: {
    events: {} as ConnectivityEvent
  }
}).createMachine({
  id: 'connectivity',
  initial: typeof navigator !== 'undefined' && navigator.onLine === false ? 'offline' : 'online',
  states: {
    online: { on: { OFFLINE: 'offline' } },
    offline: { on: { ONLINE: 'online' } }
  }
})
