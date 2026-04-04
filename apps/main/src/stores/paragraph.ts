import { ParagraphWithIndex } from "@/models/player_control";
import { create } from "zustand";
import { devtools } from "zustand/middleware";

interface PdfParagraphStore {
  currentParagraphIndex: number;
  currentParagraph: ParagraphWithIndex;
  setCurrentParagraph: (paragraph: ParagraphWithIndex) => void;
  setCurrentParagraphIndex: (index: number) => void;
  pageNumber: number;
  setPageNumber: (pageNumber: number) => void;
  paragraphs: {
    [pageNumber: number]: ParagraphWithIndex[];
  };
  pageCount: number;
  setPageCount: (pageCount: number) => void;
  getCurrentViewParagraphs: () => ParagraphWithIndex[];
  getNextViewParagraphs: () => ParagraphWithIndex[];
  getPreviousViewParagraphs: () => ParagraphWithIndex[];
  setParagraphs: (pageNumber: number, paragraphs: ParagraphWithIndex[]) => void;
  currentViewPages: number[];
  previousViewPages: number[];
  nextViewPages: number[];
  setCurrentViewPages: (pages: number[]) => void;
  setPreviousViewPages: (pages: number[]) => void;
  setNextViewPages: (pages: number[]) => void;
}
export const usePdfParagraphStore = create<PdfParagraphStore>()(
  devtools(
    (set, get) => ({
      // Initial state
      currentParagraphIndex: 0,
      currentParagraph: "",
      pageNumber: 1,
      isDualPage: true,
      currentViewPages: [],
      previousViewPages: [],
      nextViewPages: [],
      pageCount: 0,
      // Actions
      setPageCount: (pageCount: number) => set({ pageCount: pageCount }),

      setCurrentParagraphIndex: (index: number) =>
        set({ currentParagraphIndex: index }),
      setCurrentParagraph: (paragraph: ParagraphWithIndex) =>
        set({ currentParagraph: paragraph }),
      setPageNumber: (pageNumber: number) => set({ pageNumber: pageNumber }),
      setParagraphs: (pageNumber: number, paragraphs: ParagraphWithIndex[]) =>
        set({ paragraphs: { ...get().paragraphs, [pageNumber]: paragraphs } }),
      setCurrentViewPages: (pages: number[]) =>
        set({ currentViewPages: pages }),
      setPreviousViewPages: (pages: number[]) =>
        set({ previousViewPages: pages }),
      setNextViewPages: (pages: number[]) => set({ nextViewPages: pages }),
      getCurrentViewParagraphs: () => {
        const { currentViewPages } = get();
        return currentViewPages
          .map((pageNumber) => get().paragraphs[pageNumber])
          .flat();
      },
      getNextViewParagraphs: () => {
        const { nextViewPages } = get();
        return nextViewPages
          .map((pageNumber) => get().paragraphs[pageNumber])
          .flat();
      },
      getPreviousViewParagraphs: () => {
        const { previousViewPages } = get();
        return previousViewPages
          .map((pageNumber) => get().paragraphs[pageNumber])
          .flat();
      },
    }),
    {
      name: "pdf-paragraph-store", // Name for the store in devtools
    }
  )
);
