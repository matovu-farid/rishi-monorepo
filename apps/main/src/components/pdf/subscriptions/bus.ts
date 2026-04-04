import { eventBus, EventBusEvent } from "@/utils/bus";
import { nextPage, previousPage } from "../utils/pageControls";
import { customStore } from "@/stores/jotai";
import { highlightedParagraphIndexAtom, isHighlightingAtom } from "../atoms/paragraph-atoms";

eventBus.subscribe(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, async () => {
  nextPage();
});

eventBus.subscribe(
  EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED,
  async () => {
    previousPage();
  }
);
eventBus.subscribe(EventBusEvent.PLAYING_AUDIO, async (paragraph) => {
  customStore.set(isHighlightingAtom, true);
  customStore.set(highlightedParagraphIndexAtom, paragraph.index);
});


