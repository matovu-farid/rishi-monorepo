import { type ReactNode, useCallback, useEffect, useRef } from 'react'
import { type SwipeableProps, useSwipeable } from 'react-swipeable'
import { useWheel } from '@use-gesture/react'

export interface SwipeWrapperProps {
  children: ReactNode
  swipeProps: Partial<SwipeableProps>
  onSwipeLeft?: () => void
  onSwipeRight?: () => void
  /** When false, render children passthrough without any gesture wiring.
   *  Used by the EPUB reader when an external gesture layer (e.g.
   *  useReaderGesture) owns swipe/wheel handling and SwipeWrapper would
   *  otherwise intercept mousedown/wheel events. Defaults to true. */
  swipeable?: boolean
}

const DEBOUNCE_MS = 600
const THRESHOLD = 300

/**
 * SwipeWrapper Component
 * Wraps the reader with touch gesture and trackpad swipe support.
 * Touch swipes use react-swipeable; trackpad horizontal scrolling
 * uses @use-gesture/react with accumulation + debounce logic.
 *
 * When `swipeable={false}`, this component becomes a passthrough wrapper
 * that does NOT install any pointer-event or wheel listeners, leaving
 * external gesture layers free to handle the events themselves.
 */
export function SwipeWrapper({
  children,
  swipeProps,
  onSwipeLeft,
  onSwipeRight,
  swipeable = true
}: SwipeWrapperProps) {
  if (!swipeable) {
    return <SwipeWrapperPassthrough>{children}</SwipeWrapperPassthrough>
  }
  return (
    <SwipeWrapperActive
      swipeProps={swipeProps}
      onSwipeLeft={onSwipeLeft}
      onSwipeRight={onSwipeRight}
    >
      {children}
    </SwipeWrapperActive>
  )
}

/** Plain passthrough div. No gesture wiring at all. */
function SwipeWrapperPassthrough({ children }: { children: ReactNode }) {
  return <div style={{ height: '100%' }}>{children}</div>
}

/** The original gesture-active wrapper. Renamed for clarity but functionally
 *  identical to the pre-Phase-0 SwipeWrapper body. */
function SwipeWrapperActive({
  children,
  swipeProps,
  onSwipeLeft,
  onSwipeRight
}: Omit<SwipeWrapperProps, 'swipeable'>) {
  const containerRef = useRef<HTMLDivElement>(null)
  const touchHandlers = useSwipeable(swipeProps)
  const lastSwipeTime = useRef<number>(0)
  const accumulatedDeltaX = useRef<number>(0)
  const swipeConsumed = useRef<boolean>(false)

  // `useSwipeable` returns a new `ref` callback on every render. We mirror the
  // latest callback into a ref so our own `combinedRef` can stay stable, and
  // re-invoke it with the current DOM node from an effect so react-swipeable
  // always sees the up-to-date handler props.
  const touchHandlersRef = useRef(touchHandlers.ref)
  useEffect(() => {
    touchHandlersRef.current = touchHandlers.ref
    if (containerRef.current) {
      touchHandlers.ref(containerRef.current)
    }
  }, [touchHandlers])

  const wheelHandler = useCallback(
    (state: { delta: [number, number]; event: WheelEvent }) => {
      const now = Date.now()
      const { delta, event } = state
      const [deltaX, deltaY] = delta

      if (now - lastSwipeTime.current < DEBOUNCE_MS) {
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

      if (Math.abs(accumulatedDeltaX.current) >= THRESHOLD) {
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

  // Stable callback ref: stores the DOM node and forwards it to the latest
  // react-swipeable ref callback (which is a function per its typings).
  const combinedRef = useCallback((node: HTMLDivElement | null) => {
    containerRef.current = node
    touchHandlersRef.current(node)
  }, [])

  const { ref: _, ...touchHandlersWithoutRef } = touchHandlers

  return (
    <div ref={combinedRef} style={{ height: '100%' }} {...touchHandlersWithoutRef}>
      {children}
    </div>
  )
}
