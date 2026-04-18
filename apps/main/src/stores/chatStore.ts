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

        setIsChatting: (value) =>
          set((state) => ({
            isChatting: typeof value === "function" ? value(state.isChatting) : value,
          })),

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
