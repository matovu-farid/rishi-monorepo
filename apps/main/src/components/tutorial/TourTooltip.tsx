import { useEffect, useState, useCallback } from "react";
import { motion, AnimatePresence } from "framer-motion";
import type { TourStep } from "@/stores/tutorialStore";

interface TourTooltipProps {
  step: TourStep;
  stepIndex: number;
  totalSteps: number;
  isEmpty?: boolean;
  onNext: () => void;
  onSkip: () => void;
}

interface Position {
  top?: number;
  bottom?: number;
  left?: number;
  right?: number;
}

function computePosition(
  targetSelector: string,
  placement: TourStep["position"]
): Position | null {
  const el = document.querySelector(`[data-tour="${targetSelector}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const gap = 12;

  switch (placement) {
    case "below":
      return { top: r.bottom + gap, left: r.left + r.width / 2 };
    case "above":
      return { bottom: window.innerHeight - r.top + gap, left: r.left + r.width / 2 };
    case "left":
      return { top: r.top + r.height / 2, right: window.innerWidth - r.left + gap };
    case "right":
      return { top: r.top + r.height / 2, left: r.right + gap };
  }
}

function getTransformOrigin(placement: TourStep["position"]): string {
  switch (placement) {
    case "below":
      return "top center";
    case "above":
      return "bottom center";
    case "left":
      return "center right";
    case "right":
      return "center left";
  }
}

function getSlideOffset(placement: TourStep["position"]): { x: number; y: number } {
  switch (placement) {
    case "below":
      return { x: 0, y: -8 };
    case "above":
      return { x: 0, y: 8 };
    case "left":
      return { x: 8, y: 0 };
    case "right":
      return { x: -8, y: 0 };
  }
}

export function TourTooltip({
  step,
  stepIndex,
  totalSteps,
  isEmpty = false,
  onNext,
  onSkip,
}: TourTooltipProps) {
  const [pos, setPos] = useState<Position | null>(null);

  const measure = useCallback(() => {
    setPos(computePosition(step.target, step.position));
  }, [step.target, step.position]);

  useEffect(() => {
    measure();
    let timer: ReturnType<typeof setTimeout>;
    const handleResize = () => {
      clearTimeout(timer);
      timer = setTimeout(measure, 100);
    };
    window.addEventListener("resize", handleResize);
    return () => {
      window.removeEventListener("resize", handleResize);
      clearTimeout(timer);
    };
  }, [measure]);

  const isLast = stepIndex === totalSteps - 1;
  const slideOffset = getSlideOffset(step.position);

  return (
    <AnimatePresence mode="wait">
      {pos && (
        <motion.div
          key={step.target}
          className="fixed z-[60] bg-white text-gray-900 rounded-xl shadow-xl border border-gray-200 p-4 w-72"
          style={{
            top: pos.top,
            bottom: pos.bottom,
            left: pos.left,
            right: pos.right,
            transform:
              step.position === "below" || step.position === "above"
                ? "translateX(-50%)"
                : "translateY(-50%)",
            transformOrigin: getTransformOrigin(step.position),
          }}
          initial={{ opacity: 0, x: slideOffset.x, y: slideOffset.y }}
          animate={{ opacity: 1, x: 0, y: 0 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.25, ease: "easeOut" }}
        >
          <h3 className="text-sm font-semibold mb-1">{step.title}</h3>
          <p className="text-xs text-gray-500 leading-relaxed mb-3">
            {step.descriptionEmpty && isEmpty
              ? step.descriptionEmpty
              : step.description}
          </p>
          <div className="flex items-center justify-between">
            <span className="text-xs text-gray-400">
              {stepIndex + 1} of {totalSteps}
            </span>
            <div className="flex items-center gap-3">
              <button
                type="button"
                onClick={onSkip}
                className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
              >
                Skip
              </button>
              <button
                type="button"
                onClick={onNext}
                className="text-xs font-medium bg-indigo-500 hover:bg-indigo-600 text-white px-3 py-1.5 rounded-lg transition-colors"
              >
                {isLast ? "Done" : "Next →"}
              </button>
            </div>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
