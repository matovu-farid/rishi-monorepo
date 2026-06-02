import type React from 'react'
import { useEffect, useState } from 'react'

/**
 * `until` is the wire-sourced deadline (HOST_SUSPENDED frame). When the
 * worker hasn't supplied one, callers pass `null` and the banner falls back
 * to a 120s grace from the moment it mounts — matches the worker's
 * `CONFIG.HOST_GRACE_MS` so the local fallback never out-races the server
 * timeout.
 */
const FALLBACK_GRACE_MS = 120_000

export function HostSuspendedBanner({ until }: { until: number | null }): React.JSX.Element {
  // `Date.now()` is impure and forbidden during render (react-hooks/purity).
  // Capture both the mount-time fallback deadline and the current tick in
  // state with lazy initialisers (the only render-time path the rule
  // permits). The fallback never changes after mount — refs are forbidden
  // for this by react-hooks/refs, so a one-shot state slot it is.
  const [fallbackUntil] = useState<number>(() => Date.now() + FALLBACK_GRACE_MS)
  const [now, setNow] = useState<number>(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])
  const deadline = until ?? fallbackUntil
  const seconds = Math.max(0, Math.round((deadline - now) / 1000))
  return (
    <div
      role="alert"
      aria-live="polite"
      className="bg-yellow-200 text-yellow-900 px-3 py-2 text-sm text-center"
    >
      Host disconnected. Session will end in {seconds}s if they don&apos;t return.
    </div>
  )
}
