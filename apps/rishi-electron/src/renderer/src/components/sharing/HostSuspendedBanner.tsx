import React from 'react'
export function HostSuspendedBanner({ until }: { until: number }): React.JSX.Element {
  const seconds = Math.max(0, Math.round((until - Date.now()) / 1000))
  return (
    <div role="alert" aria-live="polite" className="bg-yellow-200 text-yellow-900 px-3 py-2 text-sm text-center">
      Host disconnected. Session will end in {seconds}s if they don't return.
    </div>
  )
}
