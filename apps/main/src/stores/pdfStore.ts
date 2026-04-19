import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { TextContent } from "react-pdf";
import type { PDFDocumentProxy } from "pdfjs-dist";
import type { ParagraphWithIndex } from "@/models/player_control";
import type { Book } from "@/generated";

export type Paragraph = ParagraphWithIndex & {
  dimensions: {
    top: number;
    bottom: number;
  };
};

export enum BookNavigationState {
  Idle,
  Navigating,
  Navigated,
}

export function isTextItem(
  item: import("react-pdf").TextItem | import("react-pdf").TextMarkedContent
): item is import("react-pdf").TextItem {
  return "str" in item;
}

interface PdfState {
  pageNumber: number;
  scrollPageNumber: number;
  pageCount: number;
  isDualPage: boolean;
  thumbnailSidebarOpen: boolean;
  pdfDocumentProxy: PDFDocumentProxy | null;
  pageNumberToPageData: Record<number, TextContent>;
  pdfsRendered: Record<string, boolean>;
  books: number[];
  book: Book | null;
  currentParagraph: ParagraphWithIndex;
  currentViewParagraphs: Paragraph[];
  nextViewParagraphs: Paragraph[];
  previousViewParagraphs: Paragraph[];
  highlightedParagraphIndex: string;
  isHighlighting: boolean;
  isTextGot: boolean;
  virtualizer: any | null;
  bookNavigationState: BookNavigationState;
  backgroundPage: number;
  isRenderedPageState: Record<number, boolean>;
  hasNavigatedToPage: boolean;
  isLookingForNextParagraph: boolean;

  setPageNumber: (n: number) => void;
  setScrollPageNumber: (n: number) => void;
  nextPage: () => void;
  previousPage: () => void;
  changePage: (offset: number) => void;
  setDualPage: (value: boolean) => void;
  setThumbnailSidebarOpen: (value: boolean | ((prev: boolean) => boolean)) => void;
  setPdfDocumentProxy: (proxy: PDFDocumentProxy | null) => void;
  setPageData: (pageNumber: number, data: TextContent) => void;
  setBook: (book: Book | null) => void;
  setPageCount: (n: number) => void;
  setCurrentParagraph: (p: ParagraphWithIndex) => void;
  setCurrentViewParagraphs: (p: Paragraph[]) => void;
  setNextViewParagraphs: (p: Paragraph[]) => void;
  setPreviousViewParagraphs: (p: Paragraph[]) => void;
  setHighlightedParagraphIndex: (index: string) => void;
  setIsHighlighting: (value: boolean) => void;
  setIsTextGot: (value: boolean) => void;
  setVirtualizer: (v: any) => void;
  setBookNavigationState: (state: BookNavigationState) => void;
  setBackgroundPage: (value: number | ((prev: number) => number)) => void;
  setHasNavigatedToPage: (value: boolean) => void;
  setIsLookingForNextParagraph: (value: boolean) => void;
  setIsPdfRendered: (bookId: string, isRendered: boolean) => void;
  isPdfRendered: (bookId: string) => boolean;
  resetParagraphState: () => void;
  addBook: (id: number) => void;
  removeBook: (id: number) => void;
  setAllBooks: (ids: number[]) => void;
}

export const usePdfStore = create<PdfState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        pageNumber: 0,
        scrollPageNumber: 0,
        pageCount: 0,
        isDualPage: false,
        thumbnailSidebarOpen: false,
        pdfDocumentProxy: null,
        pageNumberToPageData: {},
        pdfsRendered: {},
        books: [],
        book: null,
        currentParagraph: { index: "", text: "" },
        currentViewParagraphs: [],
        nextViewParagraphs: [],
        previousViewParagraphs: [],
        highlightedParagraphIndex: "",
        isHighlighting: false,
        isTextGot: false,
        virtualizer: null,
        bookNavigationState: BookNavigationState.Idle,
        backgroundPage: 1,
        isRenderedPageState: {},
        hasNavigatedToPage: false,
        isLookingForNextParagraph: false,

        setPageNumber: (n) => {
          const state = get();
          if (state.bookNavigationState === BookNavigationState.Navigating) return;
          if (state.bookNavigationState === BookNavigationState.Idle) {
            set({ bookNavigationState: BookNavigationState.Navigating });
          }
          set({ pageNumber: n });
        },
        setScrollPageNumber: (n) => set({ scrollPageNumber: n }),
        nextPage: () => {
          const s = get();
          const inc = s.isDualPage ? 2 : 1;
          s.changePage(inc);
        },
        previousPage: () => {
          const s = get();
          const inc = s.isDualPage ? 2 : 1;
          s.changePage(-inc);
        },
        changePage: (offset) => {
          const s = get();
          set({ isRenderedPageState: {} });
          const newPage = s.pageNumber + offset;
          if (newPage >= 1 && newPage <= s.pageCount) {
            get().setPageNumber(newPage);
          }
        },
        setDualPage: (value) => set({ isDualPage: value }),
        setThumbnailSidebarOpen: (value) =>
          set((state) => ({
            thumbnailSidebarOpen: typeof value === "function" ? value(state.thumbnailSidebarOpen) : value,
          })),
        setPdfDocumentProxy: (proxy) => set({ pdfDocumentProxy: proxy }),
        setPageData: (pageNumber, data) =>
          set((state) => ({
            pageNumberToPageData: { ...state.pageNumberToPageData, [pageNumber]: data },
          })),
        setBook: (book) => set({ book }),
        setPageCount: (n) => set({ pageCount: n }),
        setCurrentParagraph: (p) => set({ currentParagraph: p }),
        setCurrentViewParagraphs: (p) => set({ currentViewParagraphs: p }),
        setNextViewParagraphs: (p) => set({ nextViewParagraphs: p }),
        setPreviousViewParagraphs: (p) => set({ previousViewParagraphs: p }),
        setHighlightedParagraphIndex: (index) => set({ highlightedParagraphIndex: index }),
        setIsHighlighting: (value) => set({ isHighlighting: value }),
        setIsTextGot: (value) => set({ isTextGot: value }),
        setVirtualizer: (v) => set({ virtualizer: v }),
        setBookNavigationState: (state) => set({ bookNavigationState: state }),
        setBackgroundPage: (value) =>
          set((state) => ({
            backgroundPage: typeof value === "function" ? value(state.backgroundPage) : value,
          })),
        setHasNavigatedToPage: (value) => set({ hasNavigatedToPage: value }),
        setIsLookingForNextParagraph: (value) => set({ isLookingForNextParagraph: value }),
        setIsPdfRendered: (bookId, isRendered) =>
          set((state) => ({ pdfsRendered: { ...state.pdfsRendered, [bookId]: isRendered } })),
        isPdfRendered: (bookId) => get().pdfsRendered[bookId] ?? false,
        resetParagraphState: () =>
          set({ isDualPage: false, pageCount: 0, highlightedParagraphIndex: "", isHighlighting: false, isRenderedPageState: {} }),
        addBook: (id) => {
          const s = get();
          if (!s.books.includes(id)) {
            set({ books: [...s.books, id], pdfsRendered: { ...s.pdfsRendered, [id]: false } });
          }
        },
        removeBook: (id) => {
          const s = get();
          const { [id]: _, ...rest } = s.pdfsRendered;
          set({ books: s.books.filter((b) => b !== id), pdfsRendered: rest });
        },
        setAllBooks: (ids) => {
          const s = get();
          const newRendered: Record<string, boolean> = {};
          for (const id of ids) { newRendered[id] = s.pdfsRendered[id] ?? false; }
          set({ books: ids, pdfsRendered: newRendered });
        },
      })
    ),
    { name: "pdf-store" }
  )
);

// Side effect: sync scroll page number -> page number
usePdfStore.subscribe(
  (state) => state.scrollPageNumber,
  (scrollPageNumber) => {
    if (usePdfStore.getState().bookNavigationState !== BookNavigationState.Navigating) {
      usePdfStore.setState({ pageNumber: scrollPageNumber });
    }
  }
);
