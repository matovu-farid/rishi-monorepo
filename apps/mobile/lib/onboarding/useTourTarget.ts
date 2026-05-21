/**
 * React hook + helpers for screens to register a tour target.
 *
 * Usage:
 *   const onLayout = useTourTargetLayout('import-books')
 *   …
 *   <TouchableOpacity onLayout={onLayout} … />
 *
 * The hook returns a stable `onLayout` callback that measures the
 * absolute (window-relative) frame of the host view and registers it
 * with the onboarding registry. On unmount the target is removed so
 * the overlay never paints over a stale rect.
 *
 * RN's `onLayout` event gives view-local coordinates; we have to use
 * `measureInWindow` to get the absolute frame the overlay needs. The
 * hook does both: it accepts the local layout up-front so we have
 * *some* rect before the next layout pass, then upgrades to the
 * window-relative frame asynchronously.
 */
import { useCallback, useEffect, useRef } from 'react'
import type { LayoutChangeEvent, View } from 'react-native'

import {
  registerTourTarget,
  unregisterTourTarget,
} from './registry'

export function useTourTargetLayout(targetId: string) {
  const ref = useRef<View | null>(null)

  useEffect(() => {
    return () => {
      unregisterTourTarget(targetId)
    }
  }, [targetId])

  const onLayout = useCallback(
    (event: LayoutChangeEvent) => {
      const layout = event.nativeEvent.layout
      // Seed the registry with the view-local rect so the overlay has
      // *something* immediately.
      registerTourTarget(targetId, layout)
      // Then upgrade to window-relative coordinates once the view has
      // a stable frame.
      const node = ref.current
      if (node && typeof (node as { measureInWindow?: unknown }).measureInWindow === 'function') {
        ;(node as unknown as {
          measureInWindow: (
            cb: (x: number, y: number, width: number, height: number) => void,
          ) => void
        }).measureInWindow((x, y, width, height) => {
          registerTourTarget(targetId, { x, y, width, height })
        })
      }
    },
    [targetId],
  )

  return { ref, onLayout }
}
