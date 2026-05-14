import { useCallback, useEffect, useRef, useState } from 'react'
import type { CurlDirection } from './drawPageCurl'

export type CurlState = 'idle' | 'dragging' | 'animating'

export interface PageCurlResult {
  progress: number
  direction: CurlDirection
  active: boolean
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void
    onPointerMove: (e: React.PointerEvent) => void
    onPointerUp: (e: React.PointerEvent) => void
    onPointerCancel: (e: React.PointerEvent) => void
  }
  autoTurn: (dir: CurlDirection) => void
}

const EDGE_ZONE = 60
const COMMIT_THRESHOLD = 0.3
const AUTO_DURATION = 200
const SNAP_DURATION = 120
const VELOCITY_COMMIT = 1.2 // progress/sec -- flick to commit

function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - t, 4)
}

/**
 * Hook providing page-curl gesture detection with velocity tracking,
 * edge-zone activation, and requestAnimationFrame-driven animation.
 */
export function usePageCurl(callbacks: {
  /** Return false to reject the navigation (e.g. nav machine busy). */
  onNavigate: (dir: CurlDirection) => boolean
  onCommit: (dir: CurlDirection) => void
  onUndoNavigate: (dir: CurlDirection) => void
}): PageCurlResult {
  const [active, setActive] = useState(false)
  // `progress` and `direction` are returned to consumers and drive the
  // PageCurlOverlay render, so they must live in state. We mirror them into
  // refs so internal logic (event handlers, RAF tick) can read the live
  // value synchronously without going through a re-render.
  const [progress, setProgress] = useState(0)
  const [direction, setDirection] = useState<CurlDirection>('right')
  const progressRef = useRef(0)
  const directionRef = useRef<CurlDirection>('right')
  const stateRef = useRef<CurlState>('idle')
  const rafRef = useRef<number | null>(null)
  const containerRectRef = useRef<DOMRect | null>(null)
  const navigatedRef = useRef(false)
  // Velocity tracking
  const lastMoveTimeRef = useRef(0)
  const lastProgressRef = useRef(0)
  const velocityRef = useRef(0)

  const setProgressBoth = useCallback((p: number) => {
    progressRef.current = p
    setProgress(p)
  }, [])
  const setDirectionBoth = useCallback((d: CurlDirection) => {
    directionRef.current = d
    setDirection(d)
  }, [])

  const callbacksRef = useRef(callbacks)
  useEffect(() => {
    callbacksRef.current = callbacks
  })

  const cancelRaf = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current)
      rafRef.current = null
    }
  }, [])

  const animateTo = useCallback(
    (target: number, duration: number, onDone: () => void) => {
      cancelRaf()
      const start = progressRef.current
      const startTime = performance.now()
      stateRef.current = 'animating'

      function tick(now: number) {
        const elapsed = now - startTime
        const rawT = Math.min(elapsed / duration, 1)
        const t = easeOutQuart(rawT)
        setProgressBoth(start + (target - start) * t)

        if (rawT < 1) {
          rafRef.current = requestAnimationFrame(tick)
        } else {
          setProgressBoth(target)
          rafRef.current = null
          onDone()
        }
      }

      rafRef.current = requestAnimationFrame(tick)
    },
    [cancelRaf, setProgressBoth]
  )

  const finish = useCallback(
    (completed: boolean) => {
      const dir = directionRef.current
      if (completed && navigatedRef.current) {
        callbacksRef.current.onCommit(dir)
      } else if (!completed && navigatedRef.current) {
        callbacksRef.current.onUndoNavigate(dir)
      }
      stateRef.current = 'idle'
      setProgressBoth(0)
      navigatedRef.current = false
      setActive(false)
    },
    [setProgressBoth]
  )

  const commitOrCancel = useCallback(() => {
    const p = progressRef.current
    const v = velocityRef.current
    if (p >= COMMIT_THRESHOLD || v > VELOCITY_COMMIT) {
      animateTo(1, SNAP_DURATION, () => finish(true))
    } else {
      animateTo(0, SNAP_DURATION, () => finish(false))
    }
  }, [animateTo, finish])

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== 'idle') return
      const rect = e.currentTarget.getBoundingClientRect()
      const x = e.clientX - rect.left

      const nearRight = x > rect.width - EDGE_ZONE
      const nearLeft = x < EDGE_ZONE
      if (!nearRight && !nearLeft) return

      const dir: CurlDirection = nearRight ? 'right' : 'left'

      if (!callbacksRef.current.onNavigate(dir)) return

      e.currentTarget.setPointerCapture(e.pointerId)
      setDirectionBoth(dir)
      containerRectRef.current = rect
      stateRef.current = 'dragging'

      const W = rect.width
      const raw = dir === 'right' ? 1 - x / W : x / W
      const clamped = Math.max(0, Math.min(1, raw))
      setProgressBoth(clamped)

      velocityRef.current = 0
      lastMoveTimeRef.current = performance.now()
      lastProgressRef.current = clamped

      navigatedRef.current = true
      setActive(true)
    },
    [setDirectionBoth, setProgressBoth]
  )

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      const rect = containerRectRef.current
      if (!rect) return

      const x = e.clientX - rect.left
      const W = rect.width

      const isForward = directionRef.current === 'right'
      const raw = isForward ? 1 - x / W : x / W
      const newProgress = Math.max(0, Math.min(1, raw))

      // Exponential smoothing for velocity
      const now = performance.now()
      const dt = now - lastMoveTimeRef.current
      if (dt > 0 && dt < 100) {
        const instant = ((newProgress - lastProgressRef.current) / dt) * 1000
        velocityRef.current = 0.7 * instant + 0.3 * velocityRef.current
      }
      lastMoveTimeRef.current = now
      lastProgressRef.current = newProgress

      setProgressBoth(newProgress)
    },
    [setProgressBoth]
  )

  const onPointerUp = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const onPointerCancel = useCallback(
    (_e: React.PointerEvent) => {
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const autoTurn = useCallback(
    (dir: CurlDirection) => {
      if (stateRef.current !== 'idle') return

      if (!callbacksRef.current.onNavigate(dir)) return

      cancelRaf()
      setDirectionBoth(dir)
      setProgressBoth(0)
      stateRef.current = 'animating'
      navigatedRef.current = true
      setActive(true)

      animateTo(1, AUTO_DURATION, () => finish(true))
    },
    [cancelRaf, setDirectionBoth, setProgressBoth, animateTo, finish]
  )

  // Cancel any in-flight RAF on unmount
  useEffect(() => {
    return () => cancelRaf()
  }, [cancelRaf])

  return {
    progress,
    direction,
    active,
    pointerHandlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel
    },
    autoTurn
  }
}
