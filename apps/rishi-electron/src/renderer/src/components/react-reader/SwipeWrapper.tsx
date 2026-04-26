import { type ReactNode, useCallback, useRef } from 'react'
import { type SwipeableProps, useSwipeable } from 'react-swipeable'
import { useWheel } from '@use-gesture/react'

export interface SwipeWrapperProps {
  children: ReactNode
  swipeProps: Partial<SwipeableProps>
  onSwipeLeft?: () => void
  onSwipeRight?: () => void
}

/**
 * SwipeWrapper Component
 * Wraps the reader with touch gesture and trackpad swipe support.
 * Touch swipes use react-swipeable; trackpad horizontal scrolling
 * uses @use-gesture/react with accumulation + debounce logic.
 */
export function SwipeWrapper({
  children,
  swipeProps,
  onSwipeLeft,
  onSwipeRight
}: SwipeWrapperProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const touchHandlers = useSwipeable(swipeProps)
  const lastSwipeTime = useRef<number>(0)
  const accumulatedDeltaX = useRef<number>(0)
  const swipeConsumed = useRef<boolean>(false)
  const debounceMs = 600
  const threshold = 300

  const wheelHandler = useCallback(
    (state: { delta: [number, number]; event: WheelEvent }) => {
      const now = Date.now()
      const { delta, event } = state
      const [deltaX, deltaY] = delta

      if (now - lastSwipeTime.current < debounceMs) {
        event.preventDefault()
        return
      }

      // Ignore primarily-vertical scrolling
      if (Math.abs(deltaY) > Math.abs(deltaX)) {
        if (accumulatedDeltaX.current !== 0) {
          accumulatedDeltaX.current = 0
          swipeConsumed.current = false
        }
        return
      }

      if (swipeConsumed.current) {
        event.preventDefault()
        return
      }

      accumulatedDeltaX.current += deltaX

      if (Math.abs(accumulatedDeltaX.current) >= threshold) {
        event.preventDefault()
        swipeConsumed.current = true
        lastSwipeTime.current = now

        if (accumulatedDeltaX.current > 0 && onSwipeLeft) {
          onSwipeLeft()
        } else if (accumulatedDeltaX.current < 0 && onSwipeRight) {
          onSwipeRight()
        }

        setTimeout(() => {
          accumulatedDeltaX.current = 0
          swipeConsumed.current = false
        }, 200)
      }
    },
    [onSwipeLeft, onSwipeRight]
  )

  useWheel(wheelHandler, {
    target: containerRef,
    eventOptions: { passive: false }
  })

  // Combine refs from useSwipeable and our own container ref
  const combinedRef = useCallback(
    (node: HTMLDivElement | null) => {
      containerRef.current = node
      if (touchHandlers.ref && typeof touchHandlers.ref === 'function') {
        touchHandlers.ref(node)
      } else if (touchHandlers.ref && 'current' in touchHandlers.ref) {
        ;(touchHandlers.ref as unknown as React.RefObject<HTMLDivElement | null>).current = node
      }
    },
    [touchHandlers.ref]
  )

  const { ref: _, ...touchHandlersWithoutRef } = touchHandlers

  return (
    <div ref={combinedRef} style={{ height: '100%' }} {...touchHandlersWithoutRef}>
      {children}
    </div>
  )
}
