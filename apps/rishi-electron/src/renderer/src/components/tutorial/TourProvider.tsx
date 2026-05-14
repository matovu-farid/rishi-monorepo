import { useTutorialStore, TOUR_STEPS } from '@/stores/tutorialStore'
import { SpotlightOverlay } from './SpotlightOverlay'
import { TourTooltip } from './TourTooltip'

export function TourProvider() {
  const { tourActive, tourStep, tourPaused, nextStep, skipTour } = useTutorialStore()

  if (!tourActive || tourPaused) return null

  const step = TOUR_STEPS[tourStep] as (typeof TOUR_STEPS)[number] | undefined
  if (!step) return null

  return (
    <>
      <SpotlightOverlay targetSelector={step.target} />
      <TourTooltip
        step={step}
        stepIndex={tourStep}
        totalSteps={TOUR_STEPS.length}
        onNext={nextStep}
        onSkip={skipTour}
      />
    </>
  )
}
