import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime } from "@/modules/realtime";

interface ChatState {
  isChatting: boolean;
  realtimeSession: RealtimeSession | null;

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void;
  startChat: (bookId: number) => void;
  stopConversation: () => void;
}

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        isChatting: false,
        realtimeSession: null,

        setIsChatting: (value) => {
          const newValue =
            typeof value === "function" ? value(get().isChatting) : value;
          if (newValue) {
            // Stop TTS playback — chat and TTS are mutually exclusive
            const { usePlayerStore } = require("./playerStore");
            const send = usePlayerStore.getState().send;
            if (send) send({ type: "CHAT_STARTED" });
          }
          set({ isChatting: newValue });
        },

        startChat: (bookId: number) => {
          void startRealtime(bookId).then((session) => {
            set({ realtimeSession: session });
          });
        },

        stopConversation: () => {
          const { realtimeSession } = get();
          if (realtimeSession) {
            realtimeSession.close();
            set({ realtimeSession: null, isChatting: false });
          }
        },
      })
    ),
    { name: "chat-store" }
  )
);
