import { useEffect } from "react";
import { useTutorialStore, TOUR_STEPS } from "@/stores/tutorialStore";
import { SpotlightOverlay } from "./SpotlightOverlay";
import { TourTooltip } from "./TourTooltip";

export function TourProvider() {
  const tourActive = useTutorialStore((s) => s.tourActive);
  const tourStep = useTutorialStore((s) => s.tourStep);
  const tourPaused = useTutorialStore((s) => s.tourPaused);
  const tourCompleted = useTutorialStore((s) => s.tourCompleted);
  const nextStep = useTutorialStore((s) => s.nextStep);
  const skipTour = useTutorialStore((s) => s.skipTour);
  const resumeTour = useTutorialStore((s) => s.resumeTour);

  const currentStep = TOUR_STEPS[tourStep];

  // When tour is paused (waiting for route change), watch for the target element
  useEffect(() => {
    if (!tourActive || !tourPaused || !currentStep) return;

    const check = () => {
      const el = document.querySelector(
        `[data-tour="${currentStep.target}"]`
      );
      if (el) {
        resumeTour();
      }
    };

    // Check immediately, then poll
    check();
    const interval = setInterval(check, 500);
    return () => clearInterval(interval);
  }, [tourActive, tourPaused, currentStep, resumeTour]);

  // Don't render anything if tour isn't active or is paused
  if (!tourActive || tourPaused || tourCompleted || !currentStep) {
    return null;
  }

  return (
    <>
      <SpotlightOverlay targetSelector={currentStep.target} />
      <TourTooltip
        step={currentStep}
        stepIndex={tourStep}
        totalSteps={TOUR_STEPS.length}
        onNext={nextStep}
        onSkip={skipTour}
      />
    </>
  );
}
