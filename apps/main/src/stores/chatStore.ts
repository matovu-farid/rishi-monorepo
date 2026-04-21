import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime } from "@/modules/realtime";
import { usePlayerStore } from "./playerStore";

export type ChatStatus = "idle" | "thinking" | "speaking";

interface ChatState {
  isChatting: boolean;
  realtimeSession: RealtimeSession | null;
  chatStatus: ChatStatus;
  /** Incremented on each startChat, checked on resolve to discard stale sessions */
  _chatGeneration: number;

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
          const gen = get()._chatGeneration + 1;
          set({ _chatGeneration: gen });

          void startRealtime(bookId).then((session) => {
            // If chat was stopped before the session connected, close it immediately
            if (get()._chatGeneration !== gen || !get().isChatting) {
              session.close();
              return;
            }
            set({ realtimeSession: session });
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
          if (realtimeSession) {
            realtimeSession.close();
          }
        },
      })
    ),
    { name: "chat-store" }
  )
);
