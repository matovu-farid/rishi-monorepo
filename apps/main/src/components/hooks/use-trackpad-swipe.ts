import { useCallback, useRef, useEffect } from "react";

export interface TrackpadSwipeOptions {
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  threshold?: number; // Minimum deltaX to trigger swipe
  debounceMs?: number; // Debounce duration in milliseconds
  gestureEndTimeout?: number; // Time to wait after last wheel event to consider gesture ended
  preventScroll?: boolean; // Whether to prevent default scroll behavior
}

export interface TrackpadSwipeHandlers {
  onWheel: (event: WheelEvent) => void;
}

/**
 * Custom hook for detecting trackpad swipe gestures
 * Uses a "swipe session" approach to ensure only one page turn per swipe gesture
 */
export function useTrackpadSwipe(
  options: TrackpadSwipeOptions = {}
): TrackpadSwipeHandlers {
  const {
    onSwipeLeft,
    onSwipeRight,
    threshold = 50, // Minimum horizontal scroll distance to trigger swipe
    debounceMs = 300, // 300ms debounce to prevent multiple swipes
    gestureEndTimeout = 150, // Time to wait after last wheel event before allowing new swipe
    preventScroll = true,
  } = options;

  const lastSwipeTime = useRef<number>(0);
  const accumulatedDeltaX = useRef<number>(0);
  const isSwipeInProgress = useRef<boolean>(false);
  const swipeConsumed = useRef<boolean>(false); // Track if we've already triggered a swipe in this gesture
  const gestureEndTimeoutRef = useRef<number | null>(null);

  const resetGesture = useCallback(() => {
    accumulatedDeltaX.current = 0;
    isSwipeInProgress.current = false;
    swipeConsumed.current = false;
  }, []);

  const handleWheel = useCallback(
    (event: WheelEvent) => {
      const now = Date.now();

      // Check if we're still in debounce period from a previous swipe
      if (now - lastSwipeTime.current < debounceMs) {
        if (preventScroll) {
          event.preventDefault();
        }
        return;
      }

      // Only handle horizontal scrolling (trackpad swipes)
      // deltaX > 0 = swipe left, deltaX < 0 = swipe right
      const { deltaX, deltaY } = event;

      // Ignore if this is primarily vertical scrolling
      if (Math.abs(deltaY) > Math.abs(deltaX)) {
        // If we were tracking a horizontal swipe, reset it
        if (isSwipeInProgress.current) {
          resetGesture();
        }
        return;
      }

      // Clear any pending gesture end timeout
      if (gestureEndTimeoutRef.current !== null) {
        clearTimeout(gestureEndTimeoutRef.current);
        gestureEndTimeoutRef.current = null;
      }

      // If we've already consumed a swipe in this gesture, ignore further events
      if (swipeConsumed.current) {
        if (preventScroll) {
          event.preventDefault();
        }
        // Set timeout to reset gesture when wheel events stop
        gestureEndTimeoutRef.current = window.setTimeout(() => {
          resetGesture();
          gestureEndTimeoutRef.current = null;
        }, gestureEndTimeout);
        return;
      }

      // Start tracking a new swipe gesture
      if (!isSwipeInProgress.current) {
        accumulatedDeltaX.current = 0;
        isSwipeInProgress.current = true;
      }

      accumulatedDeltaX.current += deltaX;

      // Check if we've crossed the threshold
      if (Math.abs(accumulatedDeltaX.current) >= threshold) {
        if (preventScroll) {
          event.preventDefault();
        }

        // Mark swipe as consumed BEFORE triggering callback
        swipeConsumed.current = true;
        lastSwipeTime.current = now;

        // Determine swipe direction and trigger callback
        if (accumulatedDeltaX.current > 0 && onSwipeLeft) {
          onSwipeLeft();
        } else if (accumulatedDeltaX.current < 0 && onSwipeRight) {
          onSwipeRight();
        }

        // Set timeout to reset gesture when wheel events stop
        gestureEndTimeoutRef.current = window.setTimeout(() => {
          resetGesture();
          gestureEndTimeoutRef.current = null;
        }, gestureEndTimeout);
      }
    },
    [
      onSwipeLeft,
      onSwipeRight,
      threshold,
      debounceMs,
      gestureEndTimeout,
      preventScroll,
      resetGesture,
    ]
  );

  // Cleanup timeout on unmount
  useEffect(() => {
    return () => {
      if (gestureEndTimeoutRef.current !== null) {
        clearTimeout(gestureEndTimeoutRef.current);
      }
    };
  }, []);

  return {
    onWheel: handleWheel,
  };
}
