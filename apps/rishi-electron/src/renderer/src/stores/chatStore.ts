import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime, sessionCleanupMap } from "@/modules/realtime";
import { stopThinkingSound } from "@/modules/thinkingSound";
import { usePlayerStore } from "./playerStore";

export type ChatStatus = "idle" | "thinking" | "speaking";

interface ChatState {
  isChatting: boolean;
  realtimeSession: RealtimeSession | null;
  chatStatus: ChatStatus;
  _chatGeneration: number;
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
          const newValue = typeof value === "function" ? value(get().isChatting) : value;
          if (newValue) {
            const send = usePlayerStore.getState().send;
            if (send) send({ type: "CHAT_STARTED" });
          } else {
            get().stopConversation();
          }
          set({ isChatting: newValue });
        },

        setChatStatus: (status) => set({ chatStatus: status }),

        startChat: (bookId: number) => {
          if (get()._isStarting) return;
          const gen = get()._chatGeneration + 1;
          set({ _chatGeneration: gen, _isStarting: true });

          void startRealtime(bookId).then((session) => {
            if (get()._chatGeneration !== gen || !get().isChatting) {
              session.close();
              set({ _isStarting: false });
              return;
            }
            set({ realtimeSession: session, _isStarting: false });
          }).catch((err) => {
            console.error("[chat] Failed to start realtime:", err);
            set({ isChatting: false, chatStatus: "idle", _isStarting: false });
          });
        },

        stopConversation: () => {
          const { realtimeSession, _chatGeneration } = get();
          set({
            realtimeSession: null,
            isChatting: false,
            chatStatus: "idle",
            _chatGeneration: _chatGeneration + 1,
          });
          stopThinkingSound();
          if (realtimeSession) {
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
