import { useEffect } from "react";

interface ShortcutHandlers {
  onRunAll: () => void;
  onStop: () => void;
  onTimeTravelPrev: () => void;
  onTimeTravelNext: () => void;
  onTimeTravelExit: () => void;
  isTimeTravelActive: boolean;
  isRunning: boolean;
}

export function useKeyboardShortcuts({
  onRunAll,
  onStop,
  onTimeTravelPrev,
  onTimeTravelNext,
  onTimeTravelExit,
  isTimeTravelActive,
  isRunning,
}: ShortcutHandlers) {
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      // Don't capture when typing in inputs
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return;
      }

      // R — re-run all tests (when not running)
      if (e.key === "r" && !e.metaKey && !e.ctrlKey && !isRunning) {
        e.preventDefault();
        onRunAll();
        return;
      }

      // Escape — stop running or exit time-travel
      if (e.key === "Escape") {
        e.preventDefault();
        if (isTimeTravelActive) {
          onTimeTravelExit();
        } else if (isRunning) {
          onStop();
        }
        return;
      }

      // Arrow Left — previous snapshot (in time-travel)
      if (e.key === "ArrowLeft" && isTimeTravelActive) {
        e.preventDefault();
        onTimeTravelPrev();
        return;
      }

      // Arrow Right — next snapshot (in time-travel)
      if (e.key === "ArrowRight" && isTimeTravelActive) {
        e.preventDefault();
        onTimeTravelNext();
        return;
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onRunAll, onStop, onTimeTravelPrev, onTimeTravelNext, onTimeTravelExit, isTimeTravelActive, isRunning]);
}
