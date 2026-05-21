/**
 * TourProvider (G28).
 *
 * Mobile equivalent of electron's `TourProvider.tsx`. Subscribes to:
 *   - `tutorialStore` for `tourActive` / `tourStep` / actions
 *   - `lib/onboarding/registry` for the current target's layout
 *
 * Renders the dimmed spotlight + tooltip overlay anchored to the
 * registered target. When the active step's target has no layout
 * registered yet (e.g. the screen is mid-mount), the overlay returns
 * `null` so we don't paint over an unknown rect. Once the target
 * registers, the registry's subscribe-notify wakes us up and we re-
 * render with the correct geometry.
 */
import { useEffect, useState } from 'react'

import {
  TOUR_STEPS,
  useTutorialStore,
} from '@/lib/stores/tutorialStore'
import {
  getTourTarget,
  subscribeTourTargets,
  type TargetLayout,
} from '@/lib/onboarding/registry'

import { SpotlightOverlay } from './SpotlightOverlay'
import { TourTooltip } from './TourTooltip'

export function TourProvider() {
  const tourActive = useTutorialStore((s) => s.tourActive)
  const tourPaused = useTutorialStore((s) => s.tourPaused)
  const tourStep = useTutorialStore((s) => s.tourStep)
  const nextStep = useTutorialStore((s) => s.nextStep)
  const skipTour = useTutorialStore((s) => s.skipTour)

  const step = TOUR_STEPS[tourStep] as (typeof TOUR_STEPS)[number] | undefined

  // Re-render whenever the target registry changes so we pick up the
  // layout the moment the target mounts. Using local state instead of
  // useSyncExternalStore keeps the test surface trivial (no concurrent
  // subtleties — RN doesn't yet enable concurrent features by default).
  const [layout, setLayout] = useState<TargetLayout | undefined>(() =>
    step ? getTourTarget(step.target) : undefined,
  )

  useEffect(() => {
    if (!step) {
      setLayout(undefined)
      return
    }
    setLayout(getTourTarget(step.target))
    const unsub = subscribeTourTargets(() => {
      setLayout(getTourTarget(step.target))
    })
    return unsub
  }, [step])

  if (!tourActive || tourPaused) return null
  if (!step) return null
  if (!layout) return null

  return (
    <>
      <SpotlightOverlay target={layout} />
      <TourTooltip
        step={step}
        stepIndex={tourStep}
        totalSteps={TOUR_STEPS.length}
        target={layout}
        onNext={nextStep}
        onSkip={skipTour}
      />
    </>
  )
}
