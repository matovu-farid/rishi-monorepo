import {
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  AlertTriangle,
  Loader2,
} from "lucide-react";
import { toast } from "react-toastify";
import { useEffect, useRef, useState, useCallback } from "react";
import player from "@/models/Player";
import { EventBusEvent, PlayingState } from "@/utils/bus";
import { eventBus } from "@/utils/bus";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { publishCurrentEpubParagraphs } from "@/stores/epubStore";

interface TTSControlsProps {
  bookId: string;
  disabled?: boolean;
}

/** Duration before the expanded pill auto-collapses (ms). */
const AUTO_DISMISS_MS = 4_000;

export default function TTSControls({
  bookId,
  disabled = false,
}: TTSControlsProps) {
  const [showError, setShowError] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const [hasShownError, setHasShownError] = useState(false);
  const error = errors.join("\n");
  const { requireAuth, AuthDialog } = useRequireAuth();

  const [playingState, setPlayingState] = useState<PlayingState>(
    PlayingState.Stopped
  );

  // --- Pill expand / collapse state ---
  const [expanded, setExpanded] = useState(false);
  const dismissTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isHoveringRef = useRef(false);

  // --- Dismiss-timer helpers ---
  const clearDismissTimer = useCallback(() => {
    if (dismissTimerRef.current !== null) {
      clearTimeout(dismissTimerRef.current);
      dismissTimerRef.current = null;
    }
  }, []);

  const startDismissTimer = useCallback(() => {
    clearDismissTimer();
    dismissTimerRef.current = setTimeout(() => {
      setExpanded(false);
    }, AUTO_DISMISS_MS);
  }, [clearDismissTimer]);

  // When playingState changes, manage auto-dismiss timer
  useEffect(() => {
    if (!expanded) return;
    if (playingState === PlayingState.Playing) {
      // Suspend timer while playing
      clearDismissTimer();
    } else if (!isHoveringRef.current) {
      // Paused / Stopped and not hovering → start countdown
      startDismissTimer();
    }
  }, [playingState, expanded, clearDismissTimer, startDismissTimer]);

  // Cleanup dismiss timer on unmount
  useEffect(() => {
    return () => clearDismissTimer();
  }, [clearDismissTimer]);

  // --- Mouse handlers for expanded pill ---
  const handleMouseEnter = () => {
    isHoveringRef.current = true;
    clearDismissTimer();
  };

  const handleMouseLeave = () => {
    isHoveringRef.current = false;
    if (expanded && playingState !== PlayingState.Playing) {
      startDismissTimer();
    }
  };

  // --- Orb click → expand ---
  const handleOrbClick = () => {
    clearDismissTimer();
    setExpanded(true);
  };

  // Combined init + cleanup effect to prevent race conditions between
  // separate effects when bookId changes. Cleanup always runs before
  // the next init, and on unmount.
  useEffect(() => {
    let active = true;
    player.cleanup(); // Clean up any previous state before re-initializing
    void player.initialize(bookId).then(() => {
      // Guard against React Strict Mode double-mount: if cleanup ran before
      // this .then() fires, don't publish stale paragraphs.
      if (!active) return;
      // Re-publish current paragraphs so the Player receives them
      // (the initial publish may have fired before the Player subscribed)
      publishCurrentEpubParagraphs();
    });
    eventBus.on(EventBusEvent.PLAYING_STATE_CHANGED, setPlayingState);
    return () => {
      active = false;
      eventBus.off(EventBusEvent.PLAYING_STATE_CHANGED, setPlayingState);
      player.cleanup();
    };
  }, [bookId]);

  // Check for errors using setTimeout to avoid cascading renders
  useEffect(() => {
    const checkForErrors = () => {
      const currentErrors = player.getErrors();
      if (currentErrors.length !== 0 && !hasShownError) {
        setShowError(true);
        setErrors(currentErrors);
        setHasShownError(true);
      } else if (currentErrors.length === 0 && hasShownError) {
        setHasShownError(false);
      }
    };

    // Use setTimeout to defer the state update
    const timeoutId = setTimeout(checkForErrors, 0);
    return () => clearTimeout(timeoutId);
  }, [hasShownError]);

  // Show error snackbar when error occurs
  const handleErrorClose = () => {
    setShowError(false);
    // Clear errors without destroying the player — cleanup() would
    // permanently abort the player, preventing any further playback.
    player.clearErrors();
  };

  const handlePlay = () => {
    // Allow pause/resume without auth since playback was already started
    if (playingState === PlayingState.Playing) {
      player.pause();
      return;
    }
    if (playingState === PlayingState.Paused) {
      player.resume();
      return;
    }
    requireAuth("tts", () => {
      void player.play();
    });
  };

  const handleStop = async () => {
    await player.stop();
  };

  const handlePrev = async () => {
    await player.prev();
  };

  const handleNext = async () => {
    await player.next();
  };

  const handleShowErrorDetails = async () => {
    const detailedInfo = await player.getDetailedErrorInfo();

    // Show a toast with the basic info
    toast.info(
      `Check console for detailed error information. Errors: ${detailedInfo.errors.length}`,
      {
        position: "top-center",
        autoClose: 5000,
      }
    );
  };

  const getPlayIcon = () => {
    if (playingState === PlayingState.Loading) {
      return <Loader2 size={24} className="animate-spin text-black/60" />;
    }
    if (playingState === PlayingState.Playing) {
      return <Pause size={24} className="text-black/60" />;
    }
    return <Play size={24} className="text-black/60" />;
  };

  const isPlaying = playingState === PlayingState.Playing;

  // --- Waveform bar heights ---
  const barHeights = [8, 14, 20, 12];

  // Shared liquid glass styles
  const glassContainer: React.CSSProperties = {
    background:
      "linear-gradient(135deg, rgba(255,255,255,0.30) 0%, rgba(255,255,255,0.12) 40%, rgba(200,210,230,0.16) 100%)",
    backdropFilter: "blur(40px) saturate(180%)",
    WebkitBackdropFilter: "blur(40px) saturate(180%)",
    border: "1px solid rgba(255,255,255,0.45)",
    boxShadow:
      "0 4px 24px rgba(0,0,0,0.08), inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)",
  };

  const glassButton: React.CSSProperties = {
    background:
      "linear-gradient(135deg, rgba(255,255,255,0.35) 0%, rgba(255,255,255,0.15) 100%)",
    backdropFilter: "blur(20px)",
    WebkitBackdropFilter: "blur(20px)",
    border: "0.5px solid rgba(255,255,255,0.35)",
    boxShadow:
      "0 1px 4px rgba(0,0,0,0.06), inset 0 0.5px 0 rgba(255,255,255,0.4)",
  };

  return (
    <>
      {AuthDialog}

      {/* Inject keyframes for waveform animation */}
      <style>{`
        @keyframes tts-waveform {
          0%, 100% { transform: scaleY(0.4); }
          50% { transform: scaleY(1); }
        }
      `}</style>

      {/* Single morphing container: orb ↔ pill */}
      <div
        onClick={!expanded ? handleOrbClick : undefined}
        onMouseEnter={expanded ? handleMouseEnter : undefined}
        onMouseLeave={expanded ? handleMouseLeave : undefined}
        className="fixed z-50 flex items-center justify-center"
        style={{
          ...glassContainer,
          // Position: bottom-right orb vs bottom-center pill
          bottom: 32,
          right: expanded ? "auto" : 32,
          left: expanded ? "50%" : "auto",
          transform: expanded ? "translateX(-50%)" : "none",
          // Size: circle vs pill
          width: expanded ? "auto" : 52,
          height: expanded ? "auto" : 52,
          borderRadius: expanded ? 40 : "50%",
          padding: expanded ? "8px 14px" : 0,
          gap: expanded ? 6 : 0,
          cursor: expanded ? "default" : "pointer",
          // Morph animation
          transitionProperty: "width, height, border-radius, padding, gap, bottom, right, left, transform",
          transitionDuration: expanded ? "250ms" : "200ms",
          transitionTimingFunction: expanded
            ? "cubic-bezier(0.34, 1.56, 0.64, 1)"
            : "ease-in-out",
        }}
      >
        {/* Collapsed: Waveform bars */}
        {!expanded && (
          <div className="flex items-center gap-[3px]">
            {barHeights.map((h, i) => (
              <div
                key={i}
                style={{
                  width: 3,
                  height: h,
                  borderRadius: 1.5,
                  backgroundColor: "rgba(0,0,0,0.50)",
                  transformOrigin: "center",
                  animation: isPlaying
                    ? `tts-waveform 0.8s ease-in-out ${i * 0.15}s infinite`
                    : "none",
                }}
              />
            ))}
          </div>
        )}

        {/* Expanded: Control buttons */}
        {expanded && (
          <>
            {/* Previous */}
            <button
              onClick={handlePrev}
              disabled={disabled || playingState === PlayingState.Loading}
              aria-label="Previous"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <SkipBack size={20} className="text-black/60" />
            </button>

            {/* Play / Pause */}
            <button
              onClick={handlePlay}
              disabled={disabled}
              aria-label={isPlaying ? "Pause" : "Play"}
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 50, height: 50 }}
            >
              {getPlayIcon()}
            </button>

            {/* Next */}
            <button
              onClick={handleNext}
              disabled={disabled || playingState === PlayingState.Loading}
              aria-label="Next"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <SkipForward size={20} className="text-black/60" />
            </button>

            {/* Stop */}
            <button
              onClick={() => void handleStop()}
              disabled={disabled || playingState !== PlayingState.Playing}
              aria-label="Stop"
              className="flex items-center justify-center rounded-full cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed transition-transform duration-150 hover:scale-105 active:scale-95"
              style={{ ...glassButton, width: 42, height: 42 }}
            >
              <Square size={20} className="text-black/55" />
            </button>

            {/* Error indicator */}
            {errors.length > 0 && (
              <button
                onClick={() => void handleShowErrorDetails()}
                aria-label="Show error details"
                className="flex items-center justify-center rounded-full cursor-pointer transition-transform duration-150 hover:scale-105 active:scale-95"
                style={{ ...glassButton, width: 36, height: 36 }}
              >
                <AlertTriangle size={16} className="text-red-500" />
              </button>
            )}
          </>
        )}
      </div>

      {/* Error Toast */}
      {showError && !!error && (
        <div className="fixed top-4 left-1/2 transform -translate-x-1/2 z-50">
          {toast.error(error, {
            position: "top-center",
            autoClose: 6000,
            hideProgressBar: false,
            closeOnClick: true,
            pauseOnHover: true,
            draggable: true,
            onClose: handleErrorClose,
          })}
        </div>
      )}
    </>
  );
}
