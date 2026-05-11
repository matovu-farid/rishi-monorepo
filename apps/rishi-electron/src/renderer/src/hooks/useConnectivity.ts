import { useSyncExternalStore } from 'react'
import { connectivityActor } from '@/modules/connectivity'

export function useIsOnline(): boolean {
  return useSyncExternalStore(
    (cb) => {
      const sub = connectivityActor.subscribe(() => cb())
      return () => sub.unsubscribe()
    },
    () => connectivityActor.getSnapshot().value === 'online',
    () => true
  )
}
