// src/renderer/src/components/pagecurl/useReaderGesture.ts
import { useCallback, useEffect, useRef, useState } from 'react'
import type { CurlDirection } from './drawPageCurl'

export type CurlState = 'idle' | 'dragging' | 'animating'

export interface ReaderGestureResult {
  progress: number
  direction: CurlDirection
  active: boolean
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void
    onPointerMove: (e: React.PointerEvent) => void
    onPointerUp: (e: React.PointerEvent) => void
    onPointerCancel: (e: React.PointerEvent) => void
  }
  wheelHandlers: {
    onWheel: (e: React.WheelEvent) => void
  }
  autoTurn: (dir: CurlDirection) => void
}

const EDGE_ZONE = 24
const COMMIT_THRESHOLD = 0.3
const AUTO_DURATION = 200
const SNAP_DURATION = 120
const VELOCITY_COMMIT = 1.2
const WHEEL_PER_TICK_MIN = 6
const WHEEL_RATIO_GATE = 1.5
const WHEEL_CUMULATIVE_THRESHOLD = 50
const WHEEL_DEBOUNCE_MS = 120

function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - t, 4)
}

export function useReaderGesture(callbacks: {
  onNavigate: (dir: CurlDirection) => boolean
  onCommit: (dir: CurlDirection) => void
  onUndoNavigate: (dir: CurlDirection) => void
}): ReaderGestureResult {
  const [active, setActive] = useState(false)
  const [progress, setProgress] = useState(0)
  const [direction, setDirection] = useState<CurlDirection>('right')
  const progressRef = useRef(0)
  const directionRef = useRef<CurlDirection>('right')
  const stateRef = useRef<CurlState>('idle')
  const rafRef = useRef<number | null>(null)
  const containerRectRef = useRef<DOMRect | null>(null)
  const navigatedRef = useRef(false)
  const lastMoveTimeRef = useRef(0)
  const lastProgressRef = useRef(0)
  const velocityRef = useRef(0)
  const touchPointersRef = useRef<Map<number, { x: number; y: number }>>(new Map())
  const wheelBufferRef = useRef(0)
  const wheelTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Helper: returns avg x of all active touch pointers
  const avgTouchX = (): number => {
    const pts = Array.from(touchPointersRef.current.values())
    if (pts.length === 0) return 0
    return pts.reduce((s, p) => s + p.x, 0) / pts.length
  }

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

  const clearWheelTimer = useCallback(() => {
    if (wheelTimerRef.current !== null) {
      clearTimeout(wheelTimerRef.current)
      wheelTimerRef.current = null
    }
  }, [])

  const animateTo = useCallback(
    (target: number, duration: number, onDone: () => void) => {
      cancelRaf()
      const start = progressRef.current
      // Short-circuit: already at target, no animation needed.
      if (start === target) {
        stateRef.current = 'animating'
        setProgressBoth(target)
        onDone()
        return
      }
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
      if (completed && navigatedRef.current) callbacksRef.current.onCommit(dir)
      else if (!completed && navigatedRef.current) callbacksRef.current.onUndoNavigate(dir)
      stateRef.current = 'idle'
      setProgressBoth(0)
      navigatedRef.current = false
      touchPointersRef.current.clear()
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
      if (e.pointerType === 'touch') {
        // Record this touch pointer
        const rect = e.currentTarget.getBoundingClientRect()
        touchPointersRef.current.set(e.pointerId, {
          x: e.clientX - rect.left,
          y: e.clientY - rect.top
        })
        // Claim only when 2 fingers down AND machine is idle
        if (touchPointersRef.current.size === 2 && stateRef.current === 'idle') {
          // Direction is provisional; refined by onPointerMove. Default 'right'.
          const dir: CurlDirection = 'right'
          if (!callbacksRef.current.onNavigate(dir)) return
          e.currentTarget.setPointerCapture(e.pointerId)
          setDirectionBoth(dir)
          containerRectRef.current = rect
          stateRef.current = 'dragging'
          setProgressBoth(0)
          velocityRef.current = 0
          lastMoveTimeRef.current = performance.now()
          lastProgressRef.current = 0
          navigatedRef.current = true
          setActive(true)
        }
        return
      }
      // Mouse/pen path: use edge-zone.
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
      if (e.pointerType === 'touch') {
        const rect = containerRectRef.current
        if (!rect) return
        const existing = touchPointersRef.current.get(e.pointerId)
        if (!existing) return
        touchPointersRef.current.set(e.pointerId, {
          x: e.clientX - rect.left,
          y: e.clientY - rect.top
        })
        if (stateRef.current !== 'dragging' || touchPointersRef.current.size < 2) return
        const avgX = avgTouchX()
        const W = rect.width
        // Treat the gesture like a horizontal drag from the right edge: progress
        // grows as the average finger position moves leftward.
        const raw = 1 - avgX / W
        const newProgress = Math.max(0, Math.min(1, raw))
        setProgressBoth(newProgress)
        return
      }
      // Mouse/pen move path.
      if (stateRef.current !== 'dragging') return
      const rect = containerRectRef.current
      if (!rect) return
      const x = e.clientX - rect.left
      const W = rect.width
      const isForward = directionRef.current === 'right'
      const raw = isForward ? 1 - x / W : x / W
      const newProgress = Math.max(0, Math.min(1, raw))
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
    (e: React.PointerEvent) => {
      if (e.pointerType === 'touch') {
        const wasMulti = touchPointersRef.current.size >= 2
        touchPointersRef.current.delete(e.pointerId)
        if (wasMulti && touchPointersRef.current.size < 2 && stateRef.current === 'dragging') {
          commitOrCancel()
        }
        return
      }
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const onPointerCancel = useCallback(
    (e: React.PointerEvent) => {
      if (e.pointerType === 'touch') {
        const wasMulti = touchPointersRef.current.size >= 2
        touchPointersRef.current.delete(e.pointerId)
        if (wasMulti && touchPointersRef.current.size < 2 && stateRef.current === 'dragging') {
          commitOrCancel()
        }
        return
      }
      if (stateRef.current !== 'dragging') return
      commitOrCancel()
    },
    [commitOrCancel]
  )

  const onWheel = useCallback(
    (e: React.WheelEvent) => {
      const dx = e.deltaX
      const dy = e.deltaY
      // Reject vertical-dominant gestures
      if (Math.abs(dy) > Math.abs(dx) * WHEEL_RATIO_GATE) {
        wheelBufferRef.current = 0
        clearWheelTimer()
        return
      }
      // Reject tiny ticks
      if (Math.abs(dx) < WHEEL_PER_TICK_MIN) return
      e.preventDefault()
      wheelBufferRef.current += dx
      clearWheelTimer()
      wheelTimerRef.current = setTimeout(() => {
        const sum = wheelBufferRef.current
        wheelBufferRef.current = 0
        wheelTimerRef.current = null
        if (Math.abs(sum) < WHEEL_CUMULATIVE_THRESHOLD) return
        if (stateRef.current !== 'idle') return
        const dir: CurlDirection = sum > 0 ? 'right' : 'left'
        if (!callbacksRef.current.onNavigate(dir)) return
        // Visual feedback via autoTurn
        cancelRaf()
        setDirectionBoth(dir)
        setProgressBoth(0)
        stateRef.current = 'animating'
        navigatedRef.current = true
        setActive(true)
        animateTo(1, AUTO_DURATION, () => finish(true))
      }, WHEEL_DEBOUNCE_MS)
    },
    [animateTo, cancelRaf, clearWheelTimer, finish, setActive, setDirectionBoth, setProgressBoth]
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

  useEffect(() => {
    return () => {
      cancelRaf()
      clearWheelTimer()
    }
  }, [cancelRaf, clearWheelTimer])

  return {
    progress,
    direction,
    active,
    pointerHandlers: { onPointerDown, onPointerMove, onPointerUp, onPointerCancel },
    wheelHandlers: { onWheel },
    autoTurn
  }
}
