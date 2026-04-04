import { type ReactNode, useCallback, useRef } from "react";
import { type SwipeableProps, useSwipeable } from "react-swipeable";
import { useWheel } from "@use-gesture/react";

// Props for the swipe gesture wrapper component
export type SwipeWrapperProps = {
  children: ReactNode;
  swipeProps: Partial<SwipeableProps>;
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
};

/**
 * SwipeWrapper Component
 * Wraps the reader with touch gesture support for mobile/tablet navigation
 * Enables swiping left/right to turn pages via touch gestures and trackpad swipes
 */
export const SwipeWrapper = ({
  children,
  swipeProps,
  onSwipeLeft,
  onSwipeRight,
}: SwipeWrapperProps) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const touchHandlers = useSwipeable(swipeProps);
  const lastSwipeTime = useRef<number>(0);
  const accumulatedDeltaX = useRef<number>(0);
  const swipeConsumed = useRef<boolean>(false);
  const debounceMs = 600; // Debounce period to prevent multiple swipes
  const threshold = 300; // Minimum horizontal scroll distance

  // Set up trackpad swipe detection using @use-gesture/react
  const wheelHandler = useCallback(
    (state: { delta: [number, number]; event: WheelEvent }) => {
      const now = Date.now();
      const { delta, event } = state;
      const [deltaX, deltaY] = delta;

      // Check debounce period from previous swipe
      if (now - lastSwipeTime.current < debounceMs) {
        event.preventDefault();
        return;
      }

      // Only handle horizontal scrolling (trackpad swipes)
      // Ignore if this is primarily vertical scrolling
      if (Math.abs(deltaY) > Math.abs(deltaX)) {
        // Reset if we were tracking a horizontal swipe
        if (accumulatedDeltaX.current !== 0) {
          accumulatedDeltaX.current = 0;
          swipeConsumed.current = false;
        }
        return;
      }

      // If we've already consumed a swipe, ignore further events
      if (swipeConsumed.current) {
        event.preventDefault();
        return;
      }

      // Accumulate horizontal delta
      accumulatedDeltaX.current += deltaX;

      // Check if we've crossed the threshold
      if (Math.abs(accumulatedDeltaX.current) >= threshold) {
        event.preventDefault();
        swipeConsumed.current = true;
        lastSwipeTime.current = now;

        // Trigger appropriate callback based on direction
        // deltaX > 0 = swipe left, deltaX < 0 = swipe right
        if (accumulatedDeltaX.current > 0 && onSwipeLeft) {
          onSwipeLeft();
        } else if (accumulatedDeltaX.current < 0 && onSwipeRight) {
          onSwipeRight();
        }

        // Reset accumulation after a delay
        setTimeout(() => {
          accumulatedDeltaX.current = 0;
          swipeConsumed.current = false;
        }, 200);
      }
    },
    [onSwipeLeft, onSwipeRight, debounceMs, threshold]
  );

  useWheel(wheelHandler, {
    target: containerRef,
    eventOptions: { passive: false },
  });

  // Combine refs if touchHandlers has a ref
  const combinedRef = useCallback(
    (node: HTMLDivElement | null) => {
      containerRef.current = node;
      if (touchHandlers.ref && typeof touchHandlers.ref === "function") {
        touchHandlers.ref(node);
      } else if (touchHandlers.ref && "current" in touchHandlers.ref) {
        (
          touchHandlers.ref as unknown as React.MutableRefObject<HTMLDivElement | null>
        ).current = node;
      }
    },
    [touchHandlers.ref]
  );

  // Extract ref from touchHandlers to avoid conflicts
  const { ref: _, ...touchHandlersWithoutRef } = touchHandlers;

  return (
    <div
      ref={combinedRef}
      style={{ height: "100%" }}
      {...touchHandlersWithoutRef}
    >
      {children}
    </div>
  );
};
