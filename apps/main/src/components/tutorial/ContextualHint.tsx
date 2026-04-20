import { useState, type ReactNode } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useTutorialStore } from "@/stores/tutorialStore";

interface ContextualHintProps {
  id: string;
  title: string;
  description: string;
  children: ReactNode;
  /** Position of the pulsing dot relative to the child */
  dotPosition?: "top-right" | "top-left" | "bottom-right" | "bottom-left";
}

export function ContextualHint({
  id,
  title,
  description,
  children,
  dotPosition = "top-right",
}: ContextualHintProps) {
  const [popoverOpen, setPopoverOpen] = useState(false);
  const tourActive = useTutorialStore((s) => s.tourActive);
  const tourCompleted = useTutorialStore((s) => s.tourCompleted);
  const hintsShown = useTutorialStore((s) => s.hintsShown);
  const dismissHint = useTutorialStore((s) => s.dismissHint);

  const isSeen = !!hintsShown[id];
  const shouldShow = !isSeen && !tourActive && tourCompleted;

  const dotPositionClasses: Record<string, string> = {
    "top-right": "-top-1 -right-1",
    "top-left": "-top-1 -left-1",
    "bottom-right": "-bottom-1 -right-1",
    "bottom-left": "-bottom-1 -left-1",
  };

  const popoverPositionClasses: Record<string, string> = {
    "top-right": "bottom-full right-0 mb-2",
    "top-left": "bottom-full left-0 mb-2",
    "bottom-right": "top-full right-0 mt-2",
    "bottom-left": "top-full left-0 mt-2",
  };

  return (
    <div className="relative">
      {children}
      {shouldShow && (
        <>
          {/* Pulsing dot */}
          <button
            type="button"
            onClick={() => setPopoverOpen(!popoverOpen)}
            className={`absolute z-[55] w-3 h-3 rounded-full bg-indigo-500 cursor-pointer ${dotPositionClasses[dotPosition]}`}
            aria-label={`Hint: ${title}`}
            style={{
              animation: "tutorial-pulse 2s ease-in-out infinite",
            }}
          />

          {/* Hint popover */}
          <AnimatePresence>
            {popoverOpen && (
              <motion.div
                className={`absolute z-[55] bg-white rounded-lg shadow-lg border border-gray-200 p-3 w-56 ${popoverPositionClasses[dotPosition]}`}
                initial={{ opacity: 0, scale: 0.95 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: 0.95 }}
                transition={{ duration: 0.15 }}
              >
                <h4 className="text-xs font-semibold text-gray-900 mb-1">
                  {title}
                </h4>
                <p className="text-xs text-gray-500 leading-relaxed mb-2">
                  {description}
                </p>
                <button
                  type="button"
                  onClick={() => {
                    setPopoverOpen(false);
                    dismissHint(id);
                  }}
                  className="text-xs font-medium text-indigo-500 hover:text-indigo-600 transition-colors"
                >
                  Got it
                </button>
              </motion.div>
            )}
          </AnimatePresence>

          {/* Pulse animation keyframes */}
          <style>{`
            @keyframes tutorial-pulse {
              0%, 100% { box-shadow: 0 0 0 0 rgba(99, 102, 241, 0.5); }
              50% { box-shadow: 0 0 0 6px rgba(99, 102, 241, 0); }
            }
          `}</style>
        </>
      )}
    </div>
  );
}
