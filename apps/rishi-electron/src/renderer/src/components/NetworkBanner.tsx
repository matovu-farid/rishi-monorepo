import { WifiOff } from 'lucide-react'
import type { JSX } from 'react'
import { useIsOnline } from '@/hooks/useConnectivity'

export function NetworkBanner(): JSX.Element | null {
  const isOnline = useIsOnline()
  if (isOnline) return null
  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed left-1/2 top-2 z-[60] flex -translate-x-1/2 items-center gap-2 rounded-full bg-amber-500 px-4 py-1.5 text-sm font-medium text-amber-950 shadow-md"
    >
      <WifiOff className="h-4 w-4" aria-hidden="true" />
      <span>You're offline. Voice chat and sync are paused until you reconnect.</span>
    </div>
  )
}
