import { useEffect } from "react";
// import {
//   Sheet,
//   SheetContent,
//   SheetHeader,
//   SheetTitle,
// } from "@/components/ui/sheet";

// Import required CSS for text and annotation layers

import {
  hasNavigatedToPageAtom,
  isPdfRenderedAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";
import { updateStoredCoverImage } from "../utils/updateStoredCoverImage";
import { Book } from "@/generated";

export function useUpdateCoverIMage(book: Book) {
  const isRendered = useAtomValue(isPdfRenderedAtom);
  const hasNavigatedToPage = useAtomValue(hasNavigatedToPageAtom);
  useEffect(() => {
    if (isRendered(book.id.toString()) && hasNavigatedToPage) {
      void updateStoredCoverImage(book);
    }
  }, [isRendered]);
}
