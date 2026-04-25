import type { Book } from "@/lib/api";
import { getBook, updateBookCover } from "@/lib/api";
import { usePdfStore } from "@/stores/pdfStore";

export async function updateStoredCoverImage(book: Book) {
  if (book.coverKind && book.coverKind != "fallback") return;
  // set page to 1
  if (usePdfStore.getState().pageNumber !== 1) {
    usePdfStore.getState().setPageNumber(1);
  }
  const canvas = document.querySelector<HTMLCanvasElement>(
    '[data-page-number="1"] canvas'
  );
  if (!canvas) return;
  console.log(">>> Found canvas for cover image extraction.");

  const blob = await new Promise<Blob | null>((resolve) => {
    canvas.toBlob(resolve);
  });
  if (!blob) return;
  console.log(">>> Extracted cover image blob from canvas.");

  await updateCoverImage(blob, book.id);
}

export async function updateCoverImage(blob: Blob, id: number) {
  const book = await getBook({ bookId: id });
  if (!book) return;
  // only update it once
  if (book.version && book.version > 0) return;
  if (book.kind != "pdf") return;
  const cover = Array.from(new Uint8Array(await blob.arrayBuffer()));

  await updateBookCover({ bookId: id, newCover: cover });
}
