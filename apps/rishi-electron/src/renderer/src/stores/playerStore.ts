import { create } from "zustand";
import { subscribeWithSelector } from "zustand/middleware";

export interface ParagraphWithIndex {
  index: string;
  text: string;
}

export type Direction = "forward" | "backward";

export type PlayerStoreState =
  | "idle" | "stopped" | "loading" | "playing"
  | "paused.clean" | "paused.stale" | "waitingForParagraphs" | "error";

interface PlayerStoreMove {
  from: ParagraphWithIndex;
  to: ParagraphWithIndex;
  direction: Direction;
}

interface PlayerStore {
  playingState: PlayerStoreState;
  activeParagraph: ParagraphWithIndex | null;
  endedParagraph: ParagraphWithIndex | null;
  lastMove: PlayerStoreMove | null;
  errors: string[];
  currentParagraphs: ParagraphWithIndex[];
  nextPageParagraphs: ParagraphWithIndex[];
  prevPageParagraphs: ParagraphWithIndex[];
  pageRequest: "next" | "prev" | null;
  send: ((event: any) => void) | null;
  setCurrentParagraphs: (p: ParagraphWithIndex[]) => void;
  setNextPageParagraphs: (p: ParagraphWithIndex[]) => void;
  setPrevPageParagraphs: (p: ParagraphWithIndex[]) => void;
  requestNextPage: () => void;
  requestPrevPage: () => void;
  clearPageRequest: () => void;
  setSend: (send: (event: any) => void) => void;
}

export const usePlayerStore = create<PlayerStore>()(
  subscribeWithSelector((set) => ({
    playingState: "idle",
    activeParagraph: null,
    endedParagraph: null,
    lastMove: null,
    errors: [],
    currentParagraphs: [],
    nextPageParagraphs: [],
    prevPageParagraphs: [],
    pageRequest: null,
    send: null,
    setCurrentParagraphs: (p) => set({ currentParagraphs: p }),
    setNextPageParagraphs: (p) => set({ nextPageParagraphs: p }),
    setPrevPageParagraphs: (p) => set({ prevPageParagraphs: p }),
    requestNextPage: () => set({ pageRequest: "next" }),
    requestPrevPage: () => set({ pageRequest: "prev" }),
    clearPageRequest: () => set({ pageRequest: null }),
    setSend: (send) => set({ send }),
  }))
);
