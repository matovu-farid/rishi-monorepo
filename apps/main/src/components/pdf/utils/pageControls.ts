import { usePdfStore } from "@/stores/pdfStore";


export function nextPage() {
  const state = usePdfStore.getState();
  const virtualizer = state.virtualizer;
  if (!virtualizer) return;
  usePdfStore.getState().setIsLookingForNextParagraph(true);
  const pageIndex = state.pageNumber - 1;
  virtualizer.scrollToIndex(pageIndex + 1, {
    align: "start",
    behavior: "auto",
  });

  usePdfStore.getState().setIsLookingForNextParagraph(false);
}
export function previousPage() {
  const state = usePdfStore.getState();
  const virtualizer = state.virtualizer;
  if (!virtualizer) return;

  usePdfStore.getState().setIsLookingForNextParagraph(true);
  const pageIndex = state.pageNumber - 1;
  virtualizer.scrollToIndex(pageIndex - 1, {
    align: "end",
    behavior: "auto",
  });

  usePdfStore.getState().setIsLookingForNextParagraph(false);
}
