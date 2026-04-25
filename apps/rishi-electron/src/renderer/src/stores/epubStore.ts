import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type Rendition from "epubjs/types/rendition";
import { useChatStore } from "./chatStore";
import { hasSavedEpubData } from "@/lib/api";
import { prefetchRealtimeKey } from "@/modules/realtime";
import { ThemeType } from "@/themes/common";

export { ThemeType };

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
        incrementRenditionCount: () => set((s) => ({ renditionCount: s.renditionCount + 1 })),
        reset: () => {
          if (_prefetchTimer) { clearTimeout(_prefetchTimer); _prefetchTimer = null; }
          if (_publishPrefetchTimer) { clearTimeout(_publishPrefetchTimer); _publishPrefetchTimer = null; }
          set({ rendition: null, paragraphRendition: null, bookId: "", currentEpubLocation: "", renditionCount: 0 });
        },
      })
    ),
    { name: "epub-store" }
  )
);

let _unsubscribers: (() => void)[] = [];

export function initEpubSubscriptions(): (() => void)[] {
  cleanupEpubSubscriptions();
  const unsubs: (() => void)[] = [];

  // Process paragraphs when rendition + bookId are set
  unsubs.push(
    useEpubStore.subscribe(
      (s) => ({ paragraphRendition: s.paragraphRendition, bookId: s.bookId }),
      (current, previous) => {
        const { paragraphRendition, bookId } = current;
        if (paragraphRendition && bookId && (
          paragraphRendition !== previous.paragraphRendition || bookId !== previous.bookId
        )) {
          void hasSavedEpubData({ bookId: Number(bookId) }).then((hasSaved) => {
            if (!hasSaved) {
              // Process epub for indexing - will be implemented by epub wrapper
              console.log("[epub] Processing paragraphs for book", bookId);
            }
          }).catch((err) => console.warn("[epub] check saved data failed:", err));
        }
      },
      { equalityFn: (a, b) => a.paragraphRendition === b.paragraphRendition && a.bookId === b.bookId }
    )
  );

  // Publish paragraphs when location changes
  unsubs.push(
    useEpubStore.subscribe(
      (s) => ({ rendition: s.rendition, location: s.currentEpubLocation }),
      (current) => {
        const { rendition, location } = current;
        if (!rendition || !location) return;
        // Paragraph publishing handled by epub component
      },
      { equalityFn: (a, b) => a.rendition === b.rendition && a.location === b.location }
    )
  );

  // Prefetch realtime key
  unsubs.push(
    useEpubStore.subscribe(
      (s) => s.bookId,
      (bookId) => { if (bookId) prefetchRealtimeKey(); }
    )
  );

  // Start chat session
  unsubs.push(
    useChatStore.subscribe(
      (s) => s.isChatting,
      (isChatting) => {
        const bookId = useEpubStore.getState().bookId;
        if (isChatting && bookId) useChatStore.getState().startChat(Number(bookId));
      }
    )
  );

  _unsubscribers = unsubs;
  return unsubs;
}

export function cleanupEpubSubscriptions() {
  _unsubscribers.forEach((u) => u());
  _unsubscribers = [];
}
