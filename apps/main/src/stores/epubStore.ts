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
        reset: () =>
          set({
            rendition: null,
            paragraphRendition: null,
            bookId: "",
            currentEpubLocation: "",
            renditionCount: 0,
          }),
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

// Side effect: when rendition + location change, publish current/next/prev paragraphs
useEpubStore.subscribe(
  (state) => ({ rendition: state.rendition, location: state.currentEpubLocation }),
  (current) => {
    const { rendition, location } = current;
    if (!rendition || !location) return;

    const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
      text: p.text,
      index: p.cfiRange,
    }));
    eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);

    void getNextViewParagraphs(rendition).then((nextParagraphs) => {
      const mapped = nextParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });

    void getPreviousViewParagraphs(rendition).then((prevParagraphs) => {
      const mapped = prevParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });
  },
  { equalityFn: (a, b) => a.rendition === b.rendition && a.location === b.location }
);

// Side effect: handle page navigation events from the Player (TTS)
eventBus.subscribe(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, async () => {
  const { rendition } = useEpubStore.getState();
  if (!rendition) return;
  await rendition.next();
  // Bump location to trigger the paragraph-publishing subscription above
  const currentLocation = useEpubStore.getState().currentEpubLocation;
  useEpubStore.getState().setCurrentEpubLocation(
    String(Number(currentLocation) + 1)
  );
});

eventBus.subscribe(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, async () => {
  const { rendition } = useEpubStore.getState();
  if (!rendition) return;
  await rendition.prev();
  const currentLocation = useEpubStore.getState().currentEpubLocation;
  useEpubStore.getState().setCurrentEpubLocation(
    String(Number(currentLocation) - 1)
  );
});

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

  void getNextViewParagraphs(rendition).then((nextParagraphs) => {
    const mapped = nextParagraphs.map((p) => ({
      text: p.text,
      index: p.cfiRange,
    }));
    eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, mapped);
  });

  void getPreviousViewParagraphs(rendition).then((prevParagraphs) => {
    const mapped = prevParagraphs.map((p) => ({
      text: p.text,
      index: p.cfiRange,
    }));
    eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, mapped);
  });
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
