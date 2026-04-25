/**
 * Library-level TTS prefetch.
 *
 * For every book that has been processed (has stored paragraph data),
 * pre-generate TTS audio for the page the user would land on when opening it.
 * Uses a text-hash based cache key so the player can find the audio even
 * though CFI ranges aren't available until the book is rendered.
 */
import { getAllPageDataByBookId, hasSavedEpubData } from "@/lib/api";
import type { Book } from "@/lib/api";
import md5 from "md5";
import { requestTTSAudio } from "./ipc_handel_functions";

/** Low priority so library prefetch doesn't compete with active playback */
const PREFETCH_PRIORITY = 0;

/**
 * Prefetch TTS audio for the page a book would open to.
 * Call from the library page after books are loaded.
 */
export async function prefetchTTSForBooks(books: Book[]) {
  for (const book of books) {
    // Don't block the loop -- fire-and-forget per book
    void prefetchSingleBook(book).catch((err) => console.warn('[tts-prefetch] prefetch failed:', err));
  }
}

async function prefetchSingleBook(book: Book) {
  // Only attempt for books that have been processed (have paragraph data in DB)
  const hasData = await hasSavedEpubData({ bookId: book.id });
  if (!hasData) return;

  // Determine what page the book would open to
  const targetPage = book.currentPage ?? 1;

  // Get stored paragraphs for this book
  const allPageData = await getAllPageDataByBookId({ bookId: book.id });
  if (!allPageData.length) return;

  // Filter to paragraphs on the target page (or first page if no match)
  let pageParagraphs = allPageData.filter((p) => p.pageNumber === targetPage);
  if (pageParagraphs.length === 0) {
    // Fall back to the earliest page available
    const minPage = Math.min(...allPageData.map((p) => p.pageNumber));
    pageParagraphs = allPageData.filter((p) => p.pageNumber === minPage);
  }

  // Queue TTS for each paragraph using text-hash key
  for (const para of pageParagraphs) {
    const text = para.data.trim();
    if (!text) continue;
    const textHashKey = `texthash:${md5(text)}`;
    try {
      await requestTTSAudio(
        book.id.toString(),
        textHashKey,
        text,
        PREFETCH_PRIORITY
      );
    } catch {
      // Non-critical -- silently continue with other paragraphs
    }
  }
}
