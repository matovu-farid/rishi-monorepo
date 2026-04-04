import { Book } from "@/generated";
import { getBook, updateBookCover } from "@/generated";
import { customStore } from "@/stores/jotai";
import { pageNumberAtom, setPageNumberAtom } from "../atoms/paragraph-atoms";

// Import required CSS for text and annotation layers

export async function updateStoredCoverImage(book: Book) {
  if (book.coverKind && book.coverKind != "fallback") return;
  // set page to 1
  if (customStore.get(pageNumberAtom) !== 1) {
    customStore.set(setPageNumberAtom, 1);
  }
  const canvas = document.querySelector<HTMLCanvasElement>("canvas");
  if (!canvas) return;
  console.log(">>> Found canvas for cover image extraction.");

  const blob = await new Promise<Blob | null>((resolve) => {
    canvas.toBlob(resolve);
  });
  if (!blob) return;
  console.log(">>> Extracted cover image blob from canvas.");

  //await syncronizedUpdateCoverImage(blob, book.id);
  await updateCoverImage(blob, book.id);
}

export async function updateCoverImage(blob: Blob, id: number) {
  const book = await getBook({ bookId: id });
  if (!book) return;
  // only update it once
  if (book.version && book.version > 0) return;
  // if (book.cover_kind && book.cover_kind != "fallback") return
  if (book.kind != "pdf") return;
  const bytes = await blob.bytes();
  const cover = Array.from(bytes);

  await updateBookCover({ bookId: id, newCover: cover });
}
