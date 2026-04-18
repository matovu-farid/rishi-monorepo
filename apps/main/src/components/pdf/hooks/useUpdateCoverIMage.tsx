import { useEffect } from "react";

// Import required CSS for text and annotation layers

import { usePdfStore } from "@/stores/pdfStore";
import { updateStoredCoverImage } from "../utils/updateStoredCoverImage";
import { Book } from "@/generated";

export function useUpdateCoverIMage(book: Book) {
  const isPdfRendered = usePdfStore((s) => s.isPdfRendered);
  const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage);
  useEffect(() => {
    if (isPdfRendered(book.id.toString()) && hasNavigatedToPage) {
      void updateStoredCoverImage(book);
    }
  }, [isPdfRendered, book, hasNavigatedToPage]);
}
