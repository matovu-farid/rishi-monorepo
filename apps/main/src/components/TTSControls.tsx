import { IconButton } from "./ui/IconButton";
import Draggable from "./ui/Draggable";
import {
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  Volume2,
  AlertTriangle,
  Info,
  Loader2,
  Mic,
  MicOff,
  CircleX,
} from "lucide-react";
import { toast } from "react-toastify";
import { useEffect, useState } from "react";
import player from "@/models/Player";
import { atom, useAtom, useAtomValue, useSetAtom } from "jotai";
import { EventBusEvent, PlayingState } from "@/utils/bus";
import { eventBus } from "@/utils/bus";
import { isChattingAtom, stopConversationAtom } from "@/stores/chat_atoms";

interface TTSControlsProps {
  bookId: string;
  disabled?: boolean;
}

const STORE_PATH = "tts-controls-position.json";

// Get default position (center-bottom of screen)
const getDefaultPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") {
    return { x: 0, y: 0 };
  }

  const defaultX = window.innerWidth / 2 - 150; // Approximate center, adjusted for component width
  const defaultY = window.innerHeight - 128; // 8rem (32px) from bottom + some offset

  return { x: defaultX, y: defaultY };
};

// Get default chat overlay position (center of screen)
const getDefaultChatPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") {
    return { x: 0, y: 0 };
  }

  const chatSize = 100; // Chat overlay is 100x100
  const defaultX = window.innerWidth / 2 - chatSize / 2;
  const defaultY = window.innerHeight / 2 - chatSize / 2;

  return { x: defaultX, y: defaultY };
};

const playerAtom = atom(player);
playerAtom.debugLabel = "playerAtom";

export default function TTSControls({
  bookId,
  disabled = false,
}: TTSControlsProps) {
  const [showError, setShowError] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const [hasShownError, setHasShownError] = useState(false);
  const player = useAtomValue(playerAtom);
  const stopConversation = useSetAtom(stopConversationAtom);
  const error = errors.join("\n");
  const [isChatting, setIsChatting] = useAtom(isChattingAtom);

  useEffect(() => {
    void (async () => {
      await player.initialize(bookId);
    })();
  }, [bookId, player]);

  const [playingState, setPlayingState] = useState<PlayingState>(
    PlayingState.Stopped
  );

  useEffect(() => {
    eventBus.on(EventBusEvent.PLAYING_STATE_CHANGED, setPlayingState);
    return () => {
      player.cleanup();
      if (isChatting) {
        stopConversation();
        setIsChatting(false);
      }
    };
  }, []);

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
  }, [player, hasShownError]);

  // Show error snackbar when error occurs
  const handleErrorClose = () => {
    setShowError(false);
    // Clear error from store
    if (player) {
      player.cleanup();
    }
  };

  const handlePlay = () => {
    if (playingState === PlayingState.Playing) {
      player.pause();
      return;
    }
    if (playingState === PlayingState.Paused) {
      player.resume();
      return;
    }
    return player.play();
  };

  const handleStop = async () => {
    await player.stop();
  };
  const toggleChat = async () => {
    setIsChatting((isChatting) => !isChatting);
  };

  const handleChat = async () => {
    void toggleChat();
  };
  const stopChat = async () => {
    void toggleChat();
    void stopConversation();
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
      return <Loader2 size={24} className="animate-spin" />;
    }
    if (playingState === PlayingState.Playing) {
      return <Pause size={24} />;
    }
    return <Play size={24} />;
  };

  return (
    <>
      {isChatting && (
        <Draggable
          storePath={STORE_PATH}
          storeKey="chatPosition"
          defaultPosition={getDefaultChatPosition}
          width={100}
          height={100}
          className="rounded-full"
        >
          <div className="absolute -top-2 -right-2" data-no-drag>
            <CircleX
              className="cursor-pointer"
              onClick={stopChat}
              color="red"
              size={24}
            />
          </div>
          <div>
            <img
              width={100}
              height={100}
              src="https://rishi-tauri.s3.us-east-1.amazonaws.com/ai.gif"
              alt="AI"
            />
          </div>
        </Draggable>
      )}
      <Draggable
        storePath={STORE_PATH}
        storeKey="position"
        defaultPosition={getDefaultPosition}
        width={300}
        height={60}
        className="tts-controls-drag-handle"
      >
        <div className="flex items-center gap-4 px-6 py-3 bg-black/80 rounded-3xl backdrop-blur-lg shadow-lg border border-white/10">
          {/* Volume Icon */}
          <Volume2
            size={20}
            className={
              playingState === PlayingState.Playing
                ? "text-white"
                : "text-white/70"
            }
          />

          {/* Previous Button */}
          <IconButton
            size="large"
            onClick={handlePrev}
            disabled={disabled || playingState === PlayingState.Loading}
            className="text-white hover:bg-white/10 disabled:text-white/30"
          >
            <SkipBack size={24} />
          </IconButton>

          {/* Play/Pause Button */}
          <IconButton
            size="large"
            onClick={handlePlay}
            disabled={disabled}
            className={`text-white hover:bg-white/10 disabled:text-white/30 ${
              playingState === PlayingState.Playing
                ? "text-white"
                : "text-white/80"
            }`}
          >
            {getPlayIcon()}
          </IconButton>

          {/* Next Button */}
          <IconButton
            size="large"
            onClick={handleNext}
            disabled={disabled || playingState === PlayingState.Loading}
            className="text-white hover:bg-white/10 disabled:text-white/30"
          >
            <SkipForward size={24} />
          </IconButton>

          {/* Stop Button */}
          <IconButton
            size="large"
            onClick={handleStop}
            disabled={disabled || playingState !== PlayingState.Playing}
            className="text-white hover:bg-white/10 disabled:text-white/30"
          >
            <Square size={24} />
          </IconButton>
          {/* Chat Button */}
          {!isChatting && (
            <IconButton
              size="large"
              onClick={handleChat}
              disabled={false}
              className="text-white hover:bg-white/10 disabled:text-white/30"
            >
              <Mic size={24} />
            </IconButton>
          )}
          {isChatting && (
            <IconButton
              size="large"
              onClick={stopChat}
              disabled={false}
              className="text-white hover:bg-white/10 disabled:text-white/30"
            >
              <MicOff size={24} />
            </IconButton>
          )}

          {/* Error Icon with detailed info button (if there's an error) */}
          {errors.length > 0 && (
            <>
              <AlertTriangle size={20} className="text-red-500" />
              <IconButton
                size="small"
                onClick={handleShowErrorDetails}
                className="text-red-500 hover:bg-red-500/10"
                title="Show detailed error information"
              >
                <Info size={16} />
              </IconButton>
            </>
          )}
        </div>
      </Draggable>

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
