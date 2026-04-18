# TTS Player Liquid Glass Pill Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the TTS player from a dark draggable bar to an Apple liquid glass expanding pill widget with auto-dismiss behavior, and relocate the mic/chat button to the reader toolbar.

**Architecture:** Single `TTSControls.tsx` refactor — replace Draggable wrapper and dark bar UI with a fixed-position liquid glass component that morphs between collapsed orb (bottom-right) and expanded pill (bottom-center). Chat/mic button extracted from TTSControls and added to each reader's `ReaderToolbar` children. Chat overlay (AI GIF) moves to reader component level.

**Tech Stack:** React, Tailwind CSS, Lucide React icons, CSS transitions with `backdrop-filter`, Zustand (chatStore)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/components/TTSControls.tsx` | Refactor | Liquid glass pill player — collapsed orb, expanded pill, auto-dismiss |
| `src/components/epub.tsx` | Modify | Add mic button to ReaderToolbar, add chat overlay |
| `src/components/pdf/components/pdf.tsx` | Modify | Add mic button to ReaderToolbar, add chat overlay |
| `src/components/mobi/MobiView.tsx` | Modify | Add mic button to ReaderToolbar, add chat overlay |
| `src/components/djvu/DjvuView.tsx` | Modify | Add mic button to ReaderToolbar, add chat overlay |

---

### Task 1: Refactor TTSControls — Liquid Glass Pill UI

**Files:**
- Modify: `apps/main/src/components/TTSControls.tsx`

- [ ] **Step 1: Replace the full TTSControls component**

Replace the entire content of `TTSControls.tsx` with the new liquid glass pill implementation:

```tsx
import {
  Play,
  Pause,
  Square,
  SkipBack,
  SkipForward,
  AlertTriangle,
  Info,
  Loader2,
} from "lucide-react";
import { toast } from "react-toastify";
import { useEffect, useState, useRef, useCallback } from "react";
import player from "@/models/Player";
import { EventBusEvent, PlayingState } from "@/utils/bus";
import { eventBus } from "@/utils/bus";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { publishCurrentEpubParagraphs } from "@/stores/epubStore";

interface TTSControlsProps {
  bookId: string;
  disabled?: boolean;
}

const DISMISS_DELAY = 4000;

export default function TTSControls({
  bookId,
  disabled = false,
}: TTSControlsProps) {
  const [expanded, setExpanded] = useState(false);
  const [showError, setShowError] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);
  const [hasShownError, setHasShownError] = useState(false);
  const dismissTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const isHoveringRef = useRef(false);
  const error = errors.join("\n");
  const { requireAuth, AuthDialog } = useRequireAuth();

  const [playingState, setPlayingState] = useState<PlayingState>(
    PlayingState.Stopped
  );

  // Player init + cleanup
  useEffect(() => {
    let active = true;
    player.cleanup();
    void player.initialize(bookId).then(() => {
      if (!active) return;
      publishCurrentEpubParagraphs();
    });
    eventBus.on(EventBusEvent.PLAYING_STATE_CHANGED, setPlayingState);
    return () => {
      active = false;
      eventBus.off(EventBusEvent.PLAYING_STATE_CHANGED, setPlayingState);
      player.cleanup();
    };
  }, [bookId]);

  // Error checking
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
    const timeoutId = setTimeout(checkForErrors, 0);
    return () => clearTimeout(timeoutId);
  }, [hasShownError]);

  // Clear dismiss timer helper
  const clearDismissTimer = useCallback(() => {
    if (dismissTimerRef.current) {
      clearTimeout(dismissTimerRef.current);
      dismissTimerRef.current = null;
    }
  }, []);

  // Start dismiss timer helper
  const startDismissTimer = useCallback(() => {
    clearDismissTimer();
    dismissTimerRef.current = setTimeout(() => {
      setExpanded(false);
    }, DISMISS_DELAY);
  }, [clearDismissTimer]);

  // When playing state changes, manage the dismiss timer
  useEffect(() => {
    if (playingState === PlayingState.Playing) {
      clearDismissTimer();
    } else if (expanded && !isHoveringRef.current) {
      startDismissTimer();
    }
  }, [playingState, expanded, clearDismissTimer, startDismissTimer]);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => clearDismissTimer();
  }, [clearDismissTimer]);

  const handleOrbClick = () => {
    setExpanded(true);
    clearDismissTimer();
  };

  const handlePillMouseEnter = () => {
    isHoveringRef.current = true;
    clearDismissTimer();
  };

  const handlePillMouseLeave = () => {
    isHoveringRef.current = false;
    if (playingState !== PlayingState.Playing) {
      startDismissTimer();
    }
  };

  const handleErrorClose = () => {
    setShowError(false);
    player.clearErrors();
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
    toast.info(
      `Check console for detailed error information. Errors: ${detailedInfo.errors.length}`,
      { position: "top-center", autoClose: 5000 }
    );
  };

  const getPlayIcon = () => {
    if (playingState === PlayingState.Loading) {
      return <Loader2 size={22} className="animate-spin" />;
    }
    if (playingState === PlayingState.Playing) {
      return <Pause size={22} />;
    }
    return <Play size={22} />;
  };

  const isPlaying = playingState === PlayingState.Playing;

  // Shared liquid glass styles
  const glassContainer = [
    "bg-gradient-to-br from-white/30 via-white/12 to-[rgba(200,210,230,0.16)]",
    "backdrop-blur-[40px] saturate-[180%]",
    "border border-white/45",
    "shadow-[0_4px_24px_rgba(0,0,0,0.08),inset_0_0_0_0.5px_rgba(255,255,255,0.3),inset_0_1px_0_rgba(255,255,255,0.5)]",
  ].join(" ");

  const glassButton = [
    "bg-gradient-to-br from-white/35 to-white/15",
    "backdrop-blur-[20px]",
    "border-[0.5px] border-white/35",
    "shadow-[0_1px_4px_rgba(0,0,0,0.06),inset_0_0.5px_0_rgba(255,255,255,0.4)]",
    "rounded-full flex items-center justify-center",
    "transition-all duration-200",
    "hover:from-white/50 hover:to-white/25 hover:scale-[1.06]",
    "hover:shadow-[0_2px_8px_rgba(0,0,0,0.1),inset_0_0.5px_0_rgba(255,255,255,0.5)]",
    "active:scale-[0.94]",
    "disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:scale-100",
  ].join(" ");

  return (
    <>
      {AuthDialog}

      {/* Single container that morphs between orb and pill */}
      <div
        className={`fixed z-50 transition-all duration-250 ${glassContainer} ${
          expanded
            ? "bottom-8 left-1/2 -translate-x-1/2 rounded-[40px] px-3.5 py-2"
            : "bottom-8 right-8 rounded-full w-[52px] h-[52px] cursor-pointer hover:scale-[1.08] active:scale-95"
        }`}
        style={{
          transitionTimingFunction: expanded
            ? "cubic-bezier(0.34, 1.56, 0.64, 1)"
            : "ease-in-out",
          transitionDuration: expanded ? "250ms" : "200ms",
        }}
        onClick={!expanded ? handleOrbClick : undefined}
        onMouseEnter={expanded ? handlePillMouseEnter : undefined}
        onMouseLeave={expanded ? handlePillMouseLeave : undefined}
      >
        {/* Collapsed: Waveform */}
        {!expanded && (
          <div className="flex items-center justify-center w-full h-full">
            <div className="flex items-center gap-[3px] h-5">
              {[8, 14, 20, 12].map((h, i) => (
                <div
                  key={i}
                  className="w-[3px] rounded-sm bg-black/55"
                  style={{
                    height: `${h}px`,
                    animation: isPlaying
                      ? `waveform-bounce 0.8s ease-in-out ${i * 0.15}s infinite alternate`
                      : "none",
                  }}
                />
              ))}
            </div>
          </div>
        )}

        {/* Expanded: Controls */}
        {expanded && (
          <div className="flex items-center gap-2">
            {/* Previous */}
            <button
              className={`w-[42px] h-[42px] ${glassButton}`}
              onClick={handlePrev}
              disabled={disabled || playingState === PlayingState.Loading}
              aria-label="Previous paragraph"
            >
              <SkipBack size={18} className="text-black/60" />
            </button>

            {/* Play/Pause */}
            <button
              className={`w-[50px] h-[50px] ${glassButton}`}
              onClick={handlePlay}
              disabled={disabled}
              aria-label={isPlaying ? "Pause" : "Play"}
            >
              <span className="text-black/60">{getPlayIcon()}</span>
            </button>

            {/* Next */}
            <button
              className={`w-[42px] h-[42px] ${glassButton}`}
              onClick={handleNext}
              disabled={disabled || playingState === PlayingState.Loading}
              aria-label="Next paragraph"
            >
              <SkipForward size={18} className="text-black/60" />
            </button>

            {/* Stop */}
            <button
              className={`w-[42px] h-[42px] ${glassButton}`}
              onClick={handleStop}
              disabled={disabled || playingState === PlayingState.Stopped}
              aria-label="Stop"
            >
              <Square size={16} className="text-black/55" />
            </button>

            {/* Error indicator */}
            {errors.length > 0 && (
              <button
                className={`w-[36px] h-[36px] ${glassButton}`}
                onClick={handleShowErrorDetails}
                aria-label="Show error details"
              >
                <AlertTriangle size={16} className="text-red-500" />
              </button>
            )}
          </div>
        )}
      </div>

      {/* Waveform animation keyframes */}
      <style>{`
        @keyframes waveform-bounce {
          0% { transform: scaleY(0.4); }
          100% { transform: scaleY(1); }
        }
      `}</style>

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
```

- [ ] **Step 2: Verify the app compiles**

Run: `cd apps/main && pnpm tsc --noEmit 2>&1 | head -30`
Expected: No type errors in TTSControls.tsx

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/TTSControls.tsx
git commit -m "feat: redesign TTS player as liquid glass expanding pill"
```

---

### Task 2: Add Mic Button to EPUB Reader Toolbar

**Files:**
- Modify: `apps/main/src/components/epub.tsx`

- [ ] **Step 1: Add chat store imports**

Add these imports at the top of `epub.tsx`, alongside the existing imports:

```tsx
import { useChatStore } from "@/stores/chatStore";
import { Mic, MicOff, CircleX } from "lucide-react";
import Draggable from "./ui/Draggable";
```

Note: `useRequireAuth` is already imported at line 44.

- [ ] **Step 2: Add chat store hooks inside the component**

Inside the `EpubReader` component function (after the existing `useRequireAuth` call at line 113), add:

```tsx
const isChatting = useChatStore((s) => s.isChatting);
const setIsChatting = useChatStore((s) => s.setIsChatting);
const stopConversation = useChatStore((s) => s.stopConversation);

const toggleChat = () => {
  setIsChatting((prev) => !prev);
};

const handleMicClick = () => {
  requireAuth("voice-input", () => {
    toggleChat();
  });
};

const handleStopChat = () => {
  toggleChat();
  stopConversation();
};

const getDefaultChatPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") return { x: 0, y: 0 };
  return {
    x: window.innerWidth / 2 - 50,
    y: window.innerHeight / 2 - 50,
  };
};
```

- [ ] **Step 3: Add mic button to the ReaderToolbar children**

In the `<ReaderToolbar>` children (after the existing `</Popover>` closing tag, before `</ReaderToolbar>`), add:

```tsx
        {!isChatting ? (
          <button
            onClick={handleMicClick}
            className={cn("p-2 rounded-md", getTextColor())}
            aria-label="Start voice chat"
          >
            <Mic size={20} />
          </button>
        ) : (
          <button
            onClick={handleStopChat}
            className={cn("p-2 rounded-md", getTextColor())}
            aria-label="Stop voice chat"
          >
            <MicOff size={20} />
          </button>
        )}
```

- [ ] **Step 4: Add chat overlay before TTSControls**

Just before the `{<TTSControls bookId={book.id.toString()} />}` line (line 678), add the chat overlay:

```tsx
      {/* Voice chat overlay */}
      {isChatting && (
        <Draggable
          storePath="tts-controls-position.json"
          storeKey="chatPosition"
          defaultPosition={getDefaultChatPosition}
          width={100}
          height={100}
          className="rounded-full"
        >
          <div className="absolute -top-2 -right-2" data-no-drag>
            <CircleX
              className="cursor-pointer"
              onClick={handleStopChat}
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
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/main && pnpm tsc --noEmit 2>&1 | head -30`
Expected: No type errors

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/components/epub.tsx
git commit -m "feat: move mic button from TTS player to epub reader toolbar"
```

---

### Task 3: Add Mic Button to PDF Reader Toolbar

**Files:**
- Modify: `apps/main/src/components/pdf/components/pdf.tsx`

- [ ] **Step 1: Add imports**

Add these imports to the top of `pdf.tsx`:

```tsx
import { useChatStore } from "@/stores/chatStore";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { Mic, MicOff, CircleX } from "lucide-react";
import Draggable from "../../ui/Draggable";
```

Note: `MessageSquare` is not currently imported in PDF reader — it doesn't have a chat button yet. We're adding the mic button.

- [ ] **Step 2: Add hooks inside the component**

Inside the PDF reader component function, add after the existing state declarations:

```tsx
const { requireAuth, AuthDialog } = useRequireAuth();
const isChatting = useChatStore((s) => s.isChatting);
const setIsChatting = useChatStore((s) => s.setIsChatting);
const stopConversation = useChatStore((s) => s.stopConversation);

const toggleChat = () => {
  setIsChatting((prev) => !prev);
};

const handleMicClick = () => {
  requireAuth("voice-input", () => {
    toggleChat();
  });
};

const handleStopChat = () => {
  toggleChat();
  stopConversation();
};

const getDefaultChatPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") return { x: 0, y: 0 };
  return {
    x: window.innerWidth / 2 - 50,
    y: window.innerHeight / 2 - 50,
  };
};
```

- [ ] **Step 3: Add mic button to ReaderToolbar children**

After the `<BookmarkButton ... />` closing tag inside `<ReaderToolbar>` (after line 283), add:

```tsx
        {!isChatting ? (
          <button
            onClick={handleMicClick}
            className={cn(
              "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10",
              getTextColor()
            )}
            aria-label="Start voice chat"
          >
            <Mic size={20} />
          </button>
        ) : (
          <button
            onClick={handleStopChat}
            className={cn(
              "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10",
              getTextColor()
            )}
            aria-label="Stop voice chat"
          >
            <MicOff size={20} />
          </button>
        )}
```

- [ ] **Step 4: Add AuthDialog and chat overlay**

Add `{AuthDialog}` near the other rendered elements. Add the chat overlay before `TTSControls`:

```tsx
      {AuthDialog}

      {/* Voice chat overlay */}
      {isChatting && (
        <Draggable
          storePath="tts-controls-position.json"
          storeKey="chatPosition"
          defaultPosition={getDefaultChatPosition}
          width={100}
          height={100}
          className="rounded-full"
        >
          <div className="absolute -top-2 -right-2" data-no-drag>
            <CircleX
              className="cursor-pointer"
              onClick={handleStopChat}
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
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/main && pnpm tsc --noEmit 2>&1 | head -30`
Expected: No type errors

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/components/pdf/components/pdf.tsx
git commit -m "feat: add mic button to PDF reader toolbar"
```

---

### Task 4: Add Mic Button to MOBI Reader Toolbar

**Files:**
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

- [ ] **Step 1: Add imports**

Add to existing imports in `MobiView.tsx`:

```tsx
import { useChatStore } from "@/stores/chatStore";
import { Mic, MicOff, CircleX } from "lucide-react";
import Draggable from "../ui/Draggable";
```

Note: `useRequireAuth` is already imported at line 23. `MessageSquare` is already imported at line 16.

- [ ] **Step 2: Add chat hooks inside the component**

After the existing `useRequireAuth` call (line 44), add:

```tsx
const isChatting = useChatStore((s) => s.isChatting);
const setIsChatting = useChatStore((s) => s.setIsChatting);
const stopConversation = useChatStore((s) => s.stopConversation);

const toggleChat = () => {
  setIsChatting((prev) => !prev);
};

const handleMicClick = () => {
  requireAuth("voice-input", () => {
    toggleChat();
  });
};

const handleStopChat = () => {
  toggleChat();
  stopConversation();
};

const getDefaultChatPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") return { x: 0, y: 0 };
  return {
    x: window.innerWidth / 2 - 50,
    y: window.innerHeight / 2 - 50,
  };
};
```

- [ ] **Step 3: Replace the existing MessageSquare chat button in ReaderToolbar**

Replace the existing chat button (lines 294-300):
```tsx
        <button
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
          className="p-2 rounded-md text-black hover:bg-black/10"
          aria-label="Open chat panel"
        >
          <MessageSquare size={20} />
        </button>
```

With the mic button and keep the chat button too:

```tsx
        <button
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
          className="p-2 rounded-md text-black hover:bg-black/10"
          aria-label="Open chat panel"
        >
          <MessageSquare size={20} />
        </button>
        {!isChatting ? (
          <button
            onClick={handleMicClick}
            className="p-2 rounded-md text-black hover:bg-black/10"
            aria-label="Start voice chat"
          >
            <Mic size={20} />
          </button>
        ) : (
          <button
            onClick={handleStopChat}
            className="p-2 rounded-md text-black hover:bg-black/10"
            aria-label="Stop voice chat"
          >
            <MicOff size={20} />
          </button>
        )}
```

- [ ] **Step 4: Add chat overlay before TTSControls**

Before the `<TTSControls bookId={book.id.toString()} />` line (line 351), add:

```tsx
      {/* Voice chat overlay */}
      {isChatting && (
        <Draggable
          storePath="tts-controls-position.json"
          storeKey="chatPosition"
          defaultPosition={getDefaultChatPosition}
          width={100}
          height={100}
          className="rounded-full"
        >
          <div className="absolute -top-2 -right-2" data-no-drag>
            <CircleX
              className="cursor-pointer"
              onClick={handleStopChat}
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
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/main && pnpm tsc --noEmit 2>&1 | head -30`
Expected: No type errors

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat: add mic button to MOBI reader toolbar"
```

---

### Task 5: Add Mic Button to DJVU Reader Toolbar

**Files:**
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`

- [ ] **Step 1: Add imports**

Add to existing imports in `DjvuView.tsx`:

```tsx
import { useChatStore } from "@/stores/chatStore";
import { Mic, MicOff, CircleX } from "lucide-react";
import Draggable from "../ui/Draggable";
```

Note: `useRequireAuth` is already imported at line 20. `MessageSquare` is already imported.

- [ ] **Step 2: Add chat hooks inside the component**

After the existing `useRequireAuth` call (line 54), add:

```tsx
const isChatting = useChatStore((s) => s.isChatting);
const setIsChatting = useChatStore((s) => s.setIsChatting);
const stopConversation = useChatStore((s) => s.stopConversation);

const toggleChat = () => {
  setIsChatting((prev) => !prev);
};

const handleMicClick = () => {
  requireAuth("voice-input", () => {
    toggleChat();
  });
};

const handleStopChat = () => {
  toggleChat();
  stopConversation();
};

const getDefaultChatPosition = (): { x: number; y: number } => {
  if (typeof window === "undefined") return { x: 0, y: 0 };
  return {
    x: window.innerWidth / 2 - 50,
    y: window.innerHeight / 2 - 50,
  };
};
```

- [ ] **Step 3: Replace the existing MessageSquare chat button in ReaderToolbar**

Replace the existing chat button (lines 374-380):
```tsx
        <button
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
          className="p-2 rounded-md text-black hover:bg-black/10"
          aria-label="Open chat panel"
        >
          <MessageSquare size={20} />
        </button>
```

With both buttons:

```tsx
        <button
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
          className="p-2 rounded-md text-black hover:bg-black/10"
          aria-label="Open chat panel"
        >
          <MessageSquare size={20} />
        </button>
        {!isChatting ? (
          <button
            onClick={handleMicClick}
            className="p-2 rounded-md text-black hover:bg-black/10"
            aria-label="Start voice chat"
          >
            <Mic size={20} />
          </button>
        ) : (
          <button
            onClick={handleStopChat}
            className="p-2 rounded-md text-black hover:bg-black/10"
            aria-label="Stop voice chat"
          >
            <MicOff size={20} />
          </button>
        )}
```

- [ ] **Step 4: Add chat overlay before TTSControls**

Before the `<TTSControls key={book.id.toString()} bookId={book.id.toString()} />` line (line 468), add:

```tsx
      {/* Voice chat overlay */}
      {isChatting && (
        <Draggable
          storePath="tts-controls-position.json"
          storeKey="chatPosition"
          defaultPosition={getDefaultChatPosition}
          width={100}
          height={100}
          className="rounded-full"
        >
          <div className="absolute -top-2 -right-2" data-no-drag>
            <CircleX
              className="cursor-pointer"
              onClick={handleStopChat}
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
```

- [ ] **Step 5: Verify compilation**

Run: `cd apps/main && pnpm tsc --noEmit 2>&1 | head -30`
Expected: No type errors

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat: add mic button to DJVU reader toolbar"
```

---

### Task 6: Final Verification

**Files:**
- All modified files

- [ ] **Step 1: Full type check**

Run: `cd apps/main && pnpm tsc --noEmit`
Expected: Clean — no errors

- [ ] **Step 2: Verify no stale imports in TTSControls**

Check that the old imports (`Draggable`, `useChatStore`, `Volume2`, `Mic`, `MicOff`, `CircleX`) are no longer in `TTSControls.tsx`:

Run: `grep -E "Draggable|useChatStore|Volume2|Mic|CircleX" apps/main/src/components/TTSControls.tsx`
Expected: No output (none of these should appear)

- [ ] **Step 3: Verify all readers still import TTSControls**

Run: `grep -r "TTSControls" apps/main/src/components/ --include="*.tsx" -l`
Expected: epub.tsx, pdf.tsx, MobiView.tsx, DjvuView.tsx all listed

- [ ] **Step 4: Verify mic button is in all reader toolbars**

Run: `grep -r "handleMicClick\|Start voice chat" apps/main/src/components/ --include="*.tsx" -l`
Expected: epub.tsx, pdf.tsx, MobiView.tsx, DjvuView.tsx all listed

- [ ] **Step 5: Build check**

Run: `cd apps/main && pnpm build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit any fixes if needed**

```bash
git add -A
git commit -m "fix: resolve any remaining issues from TTS player redesign"
```
