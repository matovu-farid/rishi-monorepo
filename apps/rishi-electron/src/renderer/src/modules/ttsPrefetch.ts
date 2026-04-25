import { ttsService } from "./ttsService";
import type { Book } from "@/lib/api";

export async function prefetchTTSForBooks(books: Book[]): Promise<void> {
  // Pre-fetch TTS for books that have page data indexed
  for (const book of books.slice(0, 3)) {
    try {
      const pageData = await window.electron.getAllPageDataByBookId(book.id);
      if (pageData.length > 0) {
        const firstPage = pageData.find((p) => p.pageNumber === 1) || pageData[0];
        if (firstPage) {
          const paragraphs = firstPage.data.split(/\n+/).filter((t) => t.trim().length > 10);
          for (const text of paragraphs.slice(0, 2)) {
            void ttsService.requestAudio(
              book.id.toString(),
              `prefetch-${book.id}-${paragraphs.indexOf(text)}`,
              text,
              0 // low priority
            );
          }
        }
      }
    } catch {
      // Silent fail for prefetch
    }
  }
}
