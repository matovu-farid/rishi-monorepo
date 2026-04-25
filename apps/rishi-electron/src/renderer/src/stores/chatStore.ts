import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime, sessionCleanupMap } from "@/modules/realtime";
import { stopThinkingSound } from "@/modules/thinkingSound";
import { usePlayerStore } from "./playerStore";
import { captureError } from "@/utils/sentry";

export type ChatStatus = "idle" | "connecting" | "thinking" | "speaking";

interface ChatState {
  isChatting: boolean;
  realtimeSession: RealtimeSession | null;
  chatStatus: ChatStatus;
  /** Incremented on each startChat, checked on resolve to discard stale sessions */
  _chatGeneration: number;
  /** True while a startRealtime() call is in flight — prevents concurrent starts */
  _isStarting: boolean;

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void;
  setChatStatus: (status: ChatStatus) => void;
  startChat: (bookId: number) => void;
  stopConversation: () => void;
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        isChatting: false,
        realtimeSession: null,
        chatStatus: "idle" as ChatStatus,
        _chatGeneration: 0,
        _isStarting: false,

        setIsChatting: (value) => {
          const newValue =
            typeof value === "function" ? value(get().isChatting) : value;
          if (newValue) {
            // Stop TTS playback — chat and TTS are mutually exclusive
            const send = usePlayerStore.getState().send;
            if (send) send({ type: "CHAT_STARTED" });
          } else {
            // Turning off chat — stop the realtime session
            get().stopConversation();
          }
          set({ isChatting: newValue });
        },

        setChatStatus: (status) => set({ chatStatus: status }),

        startChat: (bookId: number) => {
          if (get()._isStarting) return; // Prevent concurrent starts
          const gen = get()._chatGeneration + 1;
          set({ _chatGeneration: gen, _isStarting: true, chatStatus: "connecting" });

          void startRealtime(bookId).then((session) => {
            // If chat was stopped before the session connected, close it immediately
            if (get()._chatGeneration !== gen || !get().isChatting) {
              session.close();
              set({ _isStarting: false });
              return;
            }
            set({ realtimeSession: session, _isStarting: false });
          }).catch((err) => {
            captureError(err, { operation: "realtime", step: "connect" });
            set({ isChatting: false, chatStatus: "idle", _isStarting: false });
          });
        },

        stopConversation: () => {
          const { realtimeSession, _chatGeneration } = get();
          // Bump generation so any in-flight startRealtime promise is discarded
          set({
            realtimeSession: null,
            isChatting: false,
            chatStatus: "idle",
            _chatGeneration: _chatGeneration + 1,
          });
          stopThinkingSound();
          if (realtimeSession) {
            // Remove event handlers before closing to prevent zombie callbacks
            sessionCleanupMap.get(realtimeSession)?.();
            sessionCleanupMap.delete(realtimeSession);
            realtimeSession.close();
          }
        },
      })
    ),
    { name: "chat-store" }
  )
);
