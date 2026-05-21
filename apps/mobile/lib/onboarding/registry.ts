/**
 * Tour-target registry (Gap G28).
 *
 * Mobile equivalent of electron's `[data-tour="…"]` selector
 * (`SpotlightOverlay.tsx` calls `document.querySelector(...)`). React
 * Native has no DOM, so we use a tiny module-level map that screens
 * populate via `<View onLayout={…}>` and that the tour overlay reads.
 *
 * The registry is intentionally in-memory only — layouts are render-
 * time state and should not survive a reload. The store reset path
 * (`resetTour`) calls `clearTourTargets` so a fresh tour finds an
 * empty registry on restart.
 *
 * Subscribers (the overlay) get notified after every change so they
 * can re-measure / re-render without polling.
 */

export interface TargetLayout {
  x: number
  y: number
  width: number
  height: number
}

const targets = new Map<string, TargetLayout>()
const listeners = new Set<() => void>()

function notify(): void {
  for (const fn of listeners) {
    try {
      fn()
    } catch (err) {
      console.warn('[onboarding/registry] listener threw:', err)
    }
  }
}

/**
 * Register / overwrite the layout for a tour target. Called from a
 * screen's `<View onLayout={…}>` handler so the overlay knows where
 * to draw the spotlight + tooltip.
 */
export function registerTourTarget(
  id: string,
  layout: TargetLayout,
): void {
  targets.set(id, layout)
  notify()
}

/**
 * Drop a target's layout. Call this when the screen that hosts the
 * target unmounts; otherwise the overlay may draw onto a stale rect.
 */
export function unregisterTourTarget(id: string): void {
  if (targets.delete(id)) {
    notify()
  }
}

/** Read the most recently-registered layout for `id`. */
export function getTourTarget(id: string): TargetLayout | undefined {
  return targets.get(id)
}

/** Drop every registered target. */
export function clearTourTargets(): void {
  if (targets.size === 0) return
  targets.clear()
  notify()
}

/**
 * Subscribe to registry changes. Returns an unsubscribe fn. React
 * components use this through `useSyncExternalStore`.
 */
export function subscribeTourTargets(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
