/**
 * Book file operations - Electron version.
 * Uses IPC to access filesystem via main process.
 * Ported from Tauri version with full store-based book management.
 */

export interface BookData {
  id: string;
  kind: string;
  cover: number[];
  title?: string | null;
  author?: string | null;
  publisher?: string | null;
  filepath: string;
  location: string;
  coverKind?: string | null;
  version: number;
}

export async function copyBookToAppData(filePath: string): Promise<string> {
  const appDataPath = await window.electron.getAppDataPath();
  const fileName = filePath.split(/[\\/]/).pop() || "book";
  const bookPath = `${appDataPath}/${fileName}`;
  await window.electron.copyFile(filePath, bookPath);
  return bookPath;
}

export async function getBooks(): Promise<BookData[]> {
  const books = await window.electron.getStoreValue("books");
  if (!books) {
    return [];
  }
  return books as BookData[];
}

export async function getBook(id: string): Promise<BookData | undefined> {
  const books = await getBooks();
  return books.find((book) => book.id == id);
}

export async function storeBook(book: BookData): Promise<void> {
  let books = await getBooks();
  if (!books) {
    await window.electron.setStoreValue("books", [book]);
    return;
  }
  const savedBook = books.find((currBook) => currBook.id == book.id);
  if (!savedBook) {
    books.push(book);
  } else {
    books = books.map((currBook) => {
      if (currBook.id != book.id) return currBook;
      return {
        ...currBook,
        ...book,
        version: (currBook.version || 0) + 1,
      };
    });
  }
  await window.electron.setStoreValue("books", books);
}

export async function updateCoverImage(
  blob: Blob,
  id: string
): Promise<void> {
  const book = await getBook(id);
  if (!book) return;
  // only update it once
  if (book.version && book.version > 0) return;
  if (book.kind != "pdf") return;
  const cover = Array.from(new Uint8Array(await blob.arrayBuffer()));
  await updateBook({
    id: book.id,
    cover,
  });
}

export async function deleteBook(book: BookData): Promise<void> {
  const books = await getBooks();
  if (!books) return;
  const index = books.findIndex((b) => b.id === book.id);
  if (index === -1) return;
  books.splice(index, 1);
  await window.electron.setStoreValue("books", books);
}

export async function updateBook(
  bookSlice: Partial<BookData> & { id: string }
): Promise<void> {
  const book = await getBook(bookSlice.id);
  if (!book) return;
  await storeBook({ ...book, ...bookSlice });
}
