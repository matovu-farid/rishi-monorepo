import { atom } from "jotai";
import { observe } from "jotai-effect";
import { customStore } from "./jotai";
import { bookIdAtom } from "./epub_atoms";
import { startRealtime } from "@/modules/realtime";
import { RealtimeSession } from "@openai/agents/realtime";

export const isChattingAtom = atom(false);
isChattingAtom.debugLabel = "isChattingAtom";

export const realtimeSessionAtom = atom<RealtimeSession | null>(null);
realtimeSessionAtom.debugLabel = "realtimeSessionAtom";
observe((get, set) => {
  const isChatting = get(isChattingAtom);
  const bookId = get(bookIdAtom);
  if (isChatting && bookId) {
    void startRealtime(Number(bookId)).then((session) => {
      set(realtimeSessionAtom, session);
    });
  }
}, customStore);

export const stopConversationAtom = atom(null, (get, set) => {
  const chatSession = get(realtimeSessionAtom);
  if (chatSession) {
    chatSession.close();
    set(realtimeSessionAtom, null);
    set(isChattingAtom, false);
  }
});

stopConversationAtom.debugLabel = "stopConversationAtom";
