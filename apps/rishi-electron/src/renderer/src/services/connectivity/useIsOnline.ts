import { useSyncExternalStore } from 'react'
import { getConnectivityService } from '@/services'

/**
 * React hook over getConnectivityService(). Returns the current online boolean
 * and re-renders on every transition. SSR fallback assumes online.
 *
 * Replaces the legacy `hooks/useConnectivity.ts` which reached into
 * connectivityActor directly.
 */
export function useIsOnline(): boolean {
  const service = getConnectivityService()
  return useSyncExternalStore(
    (cb) => service.subscribe(() => cb()),
    () => service.isOnline(),
    () => true
  )
}
