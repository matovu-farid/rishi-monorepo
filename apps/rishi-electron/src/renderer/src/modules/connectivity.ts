import { createActor } from 'xstate'
import { connectivityMachine } from '@/machines/connectivityMachine'

export const connectivityActor = createActor(connectivityMachine)
connectivityActor.start()

if (typeof window !== 'undefined') {
  window.addEventListener('online', () => connectivityActor.send({ type: 'ONLINE' }))
  window.addEventListener('offline', () => connectivityActor.send({ type: 'OFFLINE' }))
}

export function isOnline(): boolean {
  return connectivityActor.getSnapshot().value === 'online'
}
