import { eventBus, EventBusEvent } from "@/utils/bus";
import { nextPage, previousPage } from "../utils/pageControls";
import { usePdfStore } from "@/stores/pdfStore";

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
  usePdfStore.getState().setIsHighlighting(true);
  usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index);
});
