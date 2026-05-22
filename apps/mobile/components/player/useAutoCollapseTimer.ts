import { useCallback, useEffect, useRef } from 'react'

export interface UseAutoCollapseTimerArgs {
  /** When false, no timer is ever armed. */
  expanded: boolean
  /** When true, active playback suppresses the collapse — the user is mid-paragraph. */
  isPlaying: boolean
  /** Idle threshold before the collapse fires. */
  delayMs: number
  /** Called from setTimeout when the threshold elapses. */
  onCollapse: () => void
}

export interface UseAutoCollapseTimerApi {
  /**
   * Imperative re-arm of the pending collapse. Call from each control press
   * so a user actively tapping pill controls doesn't see the pill collapse
   * out from under them mid-tap. No-op when the guard predicate
   * (`expanded && !isPlaying`) is false.
   */
  bump: () => void
}

/**
 * WGT-009 — shared auto-collapse timer for `MiniPlayer`.
 *
 * The previous MiniPlayer carried the setTimeout/clearTimeout dance in two
 * places: a `useEffect` watching `expanded` + `isPlaying`, and a
 * `bumpCollapse` callback invoked from each control press. Both shared the
 * same delay constant and the same guard predicate
 * (`expanded && !isPlaying`); any future change had to be made in both.
 *
 * The hook owns a single timer ref. The reactive arm runs from the effect
 * (re-arms whenever expanded/isPlaying/delayMs/onCollapse change); `bump()`
 * is the imperative re-arm exposed via the return value.
 */
export function useAutoCollapseTimer({
  expanded,
  isPlaying,
  delayMs,
  onCollapse,
}: UseAutoCollapseTimerArgs): UseAutoCollapseTimerApi {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Keep the latest onCollapse in a ref so `bump()` is referentially stable
  // and doesn't need to be re-created when callers pass a new closure.
  const onCollapseRef = useRef(onCollapse)
  useEffect(() => {
    onCollapseRef.current = onCollapse
  }, [onCollapse])

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current)
      timerRef.current = null
    }
  }, [])

  const arm = useCallback(
    (ms: number, guardExpanded: boolean, guardIsPlaying: boolean) => {
      clearTimer()
      if (guardExpanded && !guardIsPlaying) {
        timerRef.current = setTimeout(() => {
          timerRef.current = null
          onCollapseRef.current()
        }, ms)
      }
    },
    [clearTimer],
  )

  // Reactive arm — re-runs when the guard inputs or delay change.
  useEffect(() => {
    arm(delayMs, expanded, isPlaying)
    return clearTimer
  }, [arm, clearTimer, delayMs, expanded, isPlaying])

  const bump = useCallback(() => {
    arm(delayMs, expanded, isPlaying)
  }, [arm, delayMs, expanded, isPlaying])

  return { bump }
}
