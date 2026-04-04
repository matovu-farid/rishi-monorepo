import { atom } from "jotai";
import type Rendition from "epubjs/types/rendition";
import {
  getAllParagraphsForBook,
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs,
} from "@/epubwrapper";
import { ParagraphWithIndex } from "@/models/player_control";
import { observe } from "jotai-effect";
import { customStore } from "./jotai";
import { eventBus, EventBusEvent } from "@/utils/bus";
import { loadable } from "jotai/utils";
import { processEpubJob } from "@/modules/process_epub";
import { hasSavedEpubData } from "@/generated";
import { ThemeType } from "@/themes/common";
export const renditionAtom = atom<Rendition | null>(null);
renditionAtom.debugLabel = "renditionAtom";

export const paragraphRenditionAtom = atom<Rendition | null>(null);
paragraphRenditionAtom.debugLabel = "paragraphRenditionAtom";

export const bookIdAtom = atom<string>("");

bookIdAtom.debugLabel = "bookIdAtom";
export const currentEpubLocationAtom = atom<string>("");
currentEpubLocationAtom.debugLabel = "currentEpubLocationAtom";
export const renditionCountAtom = atom(0);
renditionCountAtom.debugLabel = "renditionCountAtom";

observe((get) => {
  const rendition = get(paragraphRenditionAtom);

  const bookId = get(bookIdAtom);
  void hasSavedEpubData({ bookId: Number(bookId) }).then((hasSaved) => {
    if (rendition && bookId && !hasSaved) {
      console.log(">>> GETTING PARAGRAPHS");
      void getAllParagraphsForBook(rendition, bookId).then((paragraphs) => {
        console.log(">>> PARAGRAPHS", paragraphs);
        void processEpubJob(Number(bookId), paragraphs);
      });
    }
  });
}, customStore);

// Write-only atoms to trigger refetch (increment version)

export const themeAtom = atom<ThemeType>(ThemeType.White);
themeAtom.debugLabel = "themeAtom";

export const getEpubCurrentViewParagraphsAtom = atom(async (get) => {
  // Depend on the version - when it changes, this will refetch
  const rendition = get(renditionAtom);
  get(currentEpubLocationAtom);

  if (rendition) {
    const paragraphs = getCurrentViewParagraphs(rendition);
    return paragraphs.map((paragraph) => ({
      text: paragraph.text,
      index: paragraph.cfiRange,
    }));
  }
  return [] as ParagraphWithIndex[];
});
getEpubCurrentViewParagraphsAtom.debugLabel =
  "getEpubCurrentViewParagraphsAtom";
observe((get) => {
  void get(getEpubCurrentViewParagraphsAtom).then((paragraphs) => {
    eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);
  });
}, customStore);
export const getEpubNextViewParagraphsAtom = atom(async (get) => {
  // Depend on version to trigger refetch

  const rendition = get(renditionAtom);
  get(currentEpubLocationAtom);
  if (rendition) {
    return await getNextViewParagraphs(rendition).then((paragraphs) =>
      paragraphs.map((paragraph) => ({
        text: paragraph.text,
        index: paragraph.cfiRange,
      }))
    );
  }
  return [] as ParagraphWithIndex[];
});
getEpubNextViewParagraphsAtom.debugLabel = "getEpubNextViewParagraphsAtom";

export const getEpubPreviousViewParagraphsAtom = atom(async (get) => {
  const rendition = get(renditionAtom);
  get(currentEpubLocationAtom);
  if (rendition) {
    return await getPreviousViewParagraphs(rendition).then((paragraphs) =>
      paragraphs.map((paragraph) => ({
        text: paragraph.text,
        index: paragraph.cfiRange,
      }))
    );
  }
  return [] as ParagraphWithIndex[];
});
getEpubPreviousViewParagraphsAtom.debugLabel =
  "getEpubPreviousViewParagraphsAtom";
export const loadableEpubNextViewParagraphsAtom = loadable(
  getEpubNextViewParagraphsAtom
);
loadableEpubNextViewParagraphsAtom.debugLabel =
  "loadableEpubNextViewParagraphsAtom";
observe((get) => {
  const loadableEpubNextViewParagraphs = get(
    loadableEpubNextViewParagraphsAtom
  );
  if (loadableEpubNextViewParagraphs.state === "hasData") {
    eventBus.publish(
      EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE,
      loadableEpubNextViewParagraphs.data
    );
  }
}, customStore);

const loadableEpubPreviousViewParagraphsAtom = loadable(
  getEpubPreviousViewParagraphsAtom
);
loadableEpubPreviousViewParagraphsAtom.debugLabel =
  "loadableEpubPreviousViewParagraphsAtom";
observe((get) => {
  const loadableEpubPreviousViewParagraphs = get(
    loadableEpubPreviousViewParagraphsAtom
  );
  if (loadableEpubPreviousViewParagraphs.state === "hasData") {
    eventBus.publish(
      EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE,
      loadableEpubPreviousViewParagraphs.data
    );
  }
}, customStore);
