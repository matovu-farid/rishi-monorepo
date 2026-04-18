import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type Rendition from "epubjs/types/rendition";
import { ThemeType } from "@/themes/common";
import {
  getAllParagraphsForBook,
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs,
} from "@/epubwrapper";
import { eventBus, EventBusEvent } from "@/utils/bus";
import { processEpubJob } from "@/modules/process_epub";
import { hasSavedEpubData } from "@/generated";
import { useChatStore } from "./chatStore";

// Module-level timers for debouncing next/prev paragraph prefetch.
// Separate timers so the subscription and publishCurrentEpubParagraphs()
// don't cancel each other's debounce.
let _prefetchTimer: ReturnType<typeof setTimeout> | null = null;
let _publishPrefetchTimer: ReturnType<typeof setTimeout> | null = null;

interface EpubState {
  rendition: Rendition | null;
  paragraphRendition: Rendition | null;
  bookId: string;
  currentEpubLocation: string;
  theme: ThemeType;
  renditionCount: number;

  setRendition: (rendition: Rendition | null) => void;
  setParagraphRendition: (rendition: Rendition | null) => void;
  setBookId: (id: string) => void;
  setCurrentEpubLocation: (location: string) => void;
  setTheme: (theme: ThemeType) => void;
  incrementRenditionCount: () => void;
  reset: () => void;
}

export const useEpubStore = create<EpubState>()(
  devtools(
    subscribeWithSelector(
      (set) => ({
        rendition: null,
        paragraphRendition: null,
        bookId: "",
        currentEpubLocation: "",
        theme: ThemeType.White,
        renditionCount: 0,

        setRendition: (rendition) => set({ rendition }),
        setParagraphRendition: (paragraphRendition) => set({ paragraphRendition }),
        setBookId: (bookId) => set({ bookId }),
        setCurrentEpubLocation: (currentEpubLocation) => set({ currentEpubLocation }),
        setTheme: (theme) => set({ theme }),
        incrementRenditionCount: () =>
          set((state) => ({ renditionCount: state.renditionCount + 1 })),
        reset: () => {
          // Cancel any pending prefetch timers
          if (_prefetchTimer) {
            clearTimeout(_prefetchTimer);
            _prefetchTimer = null;
          }
          if (_publishPrefetchTimer) {
            clearTimeout(_publishPrefetchTimer);
            _publishPrefetchTimer = null;
          }
          set({
            rendition: null,
            paragraphRendition: null,
            bookId: "",
            currentEpubLocation: "",
            renditionCount: 0,
          });
        },
      })
    ),
    { name: "epub-store" }
  )
);

// Side effect: when paragraphRendition + bookId are set, process all paragraphs
useEpubStore.subscribe(
  (state) => ({ paragraphRendition: state.paragraphRendition, bookId: state.bookId }),
  (current, previous) => {
    const { paragraphRendition, bookId } = current;
    if (paragraphRendition && bookId && (
      paragraphRendition !== previous.paragraphRendition || bookId !== previous.bookId
    )) {
      void hasSavedEpubData({ bookId: Number(bookId) }).then((hasSaved) => {
        if (!hasSaved) {
          console.log(">>> GETTING PARAGRAPHS");
          void getAllParagraphsForBook(paragraphRendition, bookId).then((paragraphs) => {
            console.log(">>> PARAGRAPHS", paragraphs);
            void processEpubJob(Number(bookId), paragraphs);
          });
        }
      });
    }
  },
  { equalityFn: (a, b) => a.paragraphRendition === b.paragraphRendition && a.bookId === b.bookId }
);

// Side effect: when rendition + location change, publish current/next/prev paragraphs.
// Current-page paragraphs are published immediately (needed for TTS playback).
// Next/prev page paragraphs are debounced to avoid wasted work during rapid page flips.
useEpubStore.subscribe(
  (state) => ({ rendition: state.rendition, location: state.currentEpubLocation }),
  (current) => {
    const { rendition, location } = current;
    if (!rendition || !location) return;

    // Current page — publish immediately (Player needs these to play)
    const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
      text: p.text,
      index: p.cfiRange,
    }));
    eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);

    // Next/prev pages — debounce so rapid page flips don't trigger wasted fetches
    if (_prefetchTimer) clearTimeout(_prefetchTimer);
    _prefetchTimer = setTimeout(() => {
      // Re-read state in case rendition changed during the debounce window
      const { rendition: r } = useEpubStore.getState();
      if (!r) return;

      void getNextViewParagraphs(r).then((nextParagraphs) => {
        const mapped = nextParagraphs.map((p) => ({
          text: p.text,
          index: p.cfiRange,
        }));
        eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, mapped);
      });

      void getPreviousViewParagraphs(r).then((prevParagraphs) => {
        const mapped = prevParagraphs.map((p) => ({
          text: p.text,
          index: p.cfiRange,
        }));
        eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, mapped);
      });
    }, 300);
  },
  { equalityFn: (a, b) => a.rendition === b.rendition && a.location === b.location }
);

// NOTE: NEXT_PAGE_PARAGRAPHS_EMPTIED and PREVIOUS_PAGE_PARAGRAPHS_EMPTIED
// are handled in epub.tsx (which also manages highlights and publishes PAGE_CHANGED).
// The location update happens via the ReactReader locationChanged callback.
// Do NOT add duplicate handlers here — it causes double page navigation and audio desync.

/**
 * Re-publish the current epub paragraphs to the event bus.
 * Call this after Player.initialize() to seed the Player with
 * paragraphs that were published before it subscribed.
 */
export function publishCurrentEpubParagraphs() {
  const { rendition, currentEpubLocation } = useEpubStore.getState();
  if (!rendition || !currentEpubLocation) return;

  const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
    text: p.text,
    index: p.cfiRange,
  }));
  eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);

  // Use a separate timer so re-publish doesn't cancel the subscription's debounce
  if (_publishPrefetchTimer) clearTimeout(_publishPrefetchTimer);
  _publishPrefetchTimer = setTimeout(() => {
    const { rendition: r } = useEpubStore.getState();
    if (!r) return;

    void getNextViewParagraphs(r).then((nextParagraphs) => {
      const mapped = nextParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });

    void getPreviousViewParagraphs(r).then((prevParagraphs) => {
      const mapped = prevParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });
  }, 300);
}

// Side effect: when isChatting turns on and bookId exists, start realtime session
useChatStore.subscribe(
  (state) => state.isChatting,
  (isChatting) => {
    const bookId = useEpubStore.getState().bookId;
    if (isChatting && bookId) {
      useChatStore.getState().startChat(Number(bookId));
    }
  }
);
