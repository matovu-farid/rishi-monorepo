import { customStore } from "@/stores/jotai";
import { isLookingForNextParagraphAtom, pageNumberAtom, virtualizerAtom } from "../atoms/paragraph-atoms";


export function nextPage() {
  const virtualizer = customStore.get(virtualizerAtom);
  customStore.set(isLookingForNextParagraphAtom, true);
  const pageIndex = customStore.get(pageNumberAtom) - 1;
  virtualizer.scrollToIndex(pageIndex + 1, {
    align: "start",
    behavior: "auto",
  });

  customStore.set(isLookingForNextParagraphAtom, false);


}
export function previousPage() {
  const virtualizer = customStore.get(virtualizerAtom);

  customStore.set(isLookingForNextParagraphAtom, true);
  const pageIndex = customStore.get(pageNumberAtom) - 1;
  virtualizer.scrollToIndex(pageIndex - 1, {
    align: "end",
    behavior: "auto",
  });

  customStore.set(isLookingForNextParagraphAtom, false);
}

