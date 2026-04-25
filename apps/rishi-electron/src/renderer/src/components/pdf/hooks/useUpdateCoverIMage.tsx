import { useEffect } from "react";

import { usePdfStore } from "@/stores/pdfStore";
import { updateStoredCoverImage } from "../utils/updateStoredCoverImage";
import type { Book } from "@/lib/api";

export function useUpdateCoverIMage(book: Book) {
  const isPdfRendered = usePdfStore((s) => s.isPdfRendered);
  const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage);
  useEffect(() => {
    if (isPdfRendered(book.id.toString()) && hasNavigatedToPage) {
      void updateStoredCoverImage(book);
    }
  }, [isPdfRendered, book, hasNavigatedToPage]);
}
