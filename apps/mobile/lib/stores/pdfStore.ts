/**
 * Mobile PDF reader state. Slimmed-down counterpart to electron's
 * `apps/rishi-electron/src/renderer/src/stores/pdfStore.ts`. Stores
 * navigation + content state surfaced to the UI; the actual pdfjs
 * proxy / page renderers live inside the WebView (see
 * `components/pdf/PdfWebReader.tsx`).
 *
 * Same selector/action surface as electron where applicable — the
 * fields it omits (`pdfDocumentProxy`, `virtualizer`, electron's
 * `pageNumberToPageData`) only make sense in a renderer that owns
 * pdfjs in-process, which the mobile WebView does not expose to JS.
 */

import { create } from 'zustand'
import type { ParagraphWithIndex } from '@rishi/shared/machines/playerMachine'
import type { PdfOutlineItem } from '@/components/pdf/pdf-webview-bridge'

/**
 * Same enum as electron — guards against scroll-watcher races during
 * programmatic page navigation (e.g. TOC tap → seek lockout until the
 * WebView reports the new page).
 */
export enum BookNavigationState {
  Idle = 'Idle',
  Navigating = 'Navigating',
  Navigated = 'Navigated',
}

interface PdfState {
  /** Most recently authoritative page number (post-seek-landed). */
  pageNumber: number
  /** Scroll-driven page reports from the WebView. */
  scrollPageNumber: number
  pageCount: number
  outline: PdfOutlineItem[]
  /** Currently-playing paragraph for TTS highlight reconciliation. */
  currentParagraph: ParagraphWithIndex
  currentViewParagraphs: ParagraphWithIndex[]
  highlightedParagraphIndex: string
  isHighlighting: boolean
  bookNavigationState: BookNavigationState

  setPageNumber: (n: number) => void
  setScrollPageNumber: (n: number) => void
  nextPage: () => void
  previousPage: () => void
  changePage: (offset: number) => void
  setPageCount: (n: number) => void
  setOutline: (o: PdfOutlineItem[]) => void
  setCurrentParagraph: (p: ParagraphWithIndex) => void
  setCurrentViewParagraphs: (p: ParagraphWithIndex[]) => void
  setHighlightedParagraphIndex: (index: string) => void
  setIsHighlighting: (value: boolean) => void
  setBookNavigationState: (s: BookNavigationState) => void
  resetParagraphState: () => void
}

export const usePdfStore = create<PdfState>((set, get) => ({
  pageNumber: 0,
  scrollPageNumber: 0,
  pageCount: 0,
  outline: [],
  currentParagraph: { index: '', text: '' },
  currentViewParagraphs: [],
  highlightedParagraphIndex: '',
  isHighlighting: false,
  bookNavigationState: BookNavigationState.Idle,

  setPageNumber: (n) => {
    const state = get()
    // Match electron's setPageNumber: while Navigating, ignore further
    // setPageNumber requests so the scroll watcher can't race a seek.
    if (state.bookNavigationState === BookNavigationState.Navigating) return
    if (state.bookNavigationState === BookNavigationState.Idle) {
      set({ bookNavigationState: BookNavigationState.Navigating })
    }
    set({ pageNumber: n })
  },
  setScrollPageNumber: (n) => {
    const state = get()
    set({ scrollPageNumber: n })
    // Side effect mirrors electron's pdfStore.subscribe: scroll updates
    // become the authoritative pageNumber only when not in a seek window.
    if (state.bookNavigationState !== BookNavigationState.Navigating) {
      set({ pageNumber: n })
    }
  },
  nextPage: () => {
    const s = get()
    s.changePage(1)
  },
  previousPage: () => {
    const s = get()
    s.changePage(-1)
  },
  changePage: (offset) => {
    const s = get()
    const newPage = s.pageNumber + offset
    if (newPage >= 1 && newPage <= s.pageCount) {
      get().setPageNumber(newPage)
    }
  },
  setPageCount: (n) => set({ pageCount: n }),
  setOutline: (o) => set({ outline: o }),
  setCurrentParagraph: (p) => set({ currentParagraph: p }),
  setCurrentViewParagraphs: (p) => set({ currentViewParagraphs: p }),
  setHighlightedParagraphIndex: (index) => set({ highlightedParagraphIndex: index }),
  setIsHighlighting: (value) => set({ isHighlighting: value }),
  setBookNavigationState: (s) => set({ bookNavigationState: s }),
  resetParagraphState: () =>
    set({
      pageCount: 0,
      outline: [],
      highlightedParagraphIndex: '',
      isHighlighting: false,
      currentParagraph: { index: '', text: '' },
      currentViewParagraphs: [],
      bookNavigationState: BookNavigationState.Idle,
    }),
}))
