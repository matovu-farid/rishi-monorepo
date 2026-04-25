// apps/main/src/stores/playerStore.ts
import { create } from "zustand";
import { subscribeWithSelector } from "zustand/middleware";
import type { ParagraphWithIndex } from "@/models/player_control";

export type { ParagraphWithIndex };

export type Direction = "forward" | "backward";

export type PlayerStoreState =
  | "idle"
  | "stopped"
  | "loading"
  | "playing"
  | "paused.clean"
  | "paused.stale"
  | "waitingForParagraphs"
  | "error";

interface PlayerStoreMove {
  from: ParagraphWithIndex;
  to: ParagraphWithIndex;
  direction: Direction;
}

interface PlayerStore {
  // --- Player-side state (written by machine, read by React) ---
  playingState: PlayerStoreState;
  activeParagraph: ParagraphWithIndex | null;
  endedParagraph: ParagraphWithIndex | null;
  lastMove: PlayerStoreMove | null;
  errors: string[];

  // --- Format-reader-side state (written by readers, read by machine) ---
  currentParagraphs: ParagraphWithIndex[];
  nextPageParagraphs: ParagraphWithIndex[];
  prevPageParagraphs: ParagraphWithIndex[];

  // --- Signals ---
  pageRequest: "next" | "prev" | null;

  // --- Machine send reference for non-React code ---
  send: ((event: any) => void) | null;

  // --- Actions: format readers call these ---
  setCurrentParagraphs: (p: ParagraphWithIndex[]) => void;
  setNextPageParagraphs: (p: ParagraphWithIndex[]) => void;
  setPrevPageParagraphs: (p: ParagraphWithIndex[]) => void;

  // --- Actions: machine calls these ---
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
