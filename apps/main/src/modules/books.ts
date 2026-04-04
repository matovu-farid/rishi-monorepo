import { BookData } from "@/generated";
import { path } from "@tauri-apps/api";
import * as fs from "@tauri-apps/plugin-fs";
import { load, Store } from "@tauri-apps/plugin-store";

export async function copyBookToAppData(filePath: string) {
  const appdataPath = await path.appDataDir();
  const fileName = await path.basename(filePath);
  const bookPath = await path.join(appdataPath, fileName);
  await fs.copyFile(filePath, bookPath);
  return bookPath;
}

export async function getBooks(storeParam?: Store) {
  let store = storeParam || (await getStore());
  const books = await store.get<BookData[]>("books");
  if (!books) {
    return [];
  }
  return books;
}

export async function getBook(id: String, storeParam?: Store) {
  let store = storeParam || (await getStore());
  const books = await getBooks(store);
  return books.find((book) => book.id == id);
}
export async function storeBook(book: BookData, storeParam?: Store) {
  let store = storeParam || (await getStore());
  let books = await getBooks(store);
  if (!books) {
    console.log(">>> No books");
    await store.set("books", [book]);
    return;
  }
  const savedBook = books.find((currBook) => currBook.id == book.id);
  if (!savedBook) {
    console.log(">>> No saved book");

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

  await store.set("books", books);
}
export async function updateCoverImage(
  blob: Blob,
  id: String,
  storeParam?: Store
) {
  let store = storeParam || (await getStore());

  const book = await getBook(id, store);
  if (!book) return;
  // only update it once
  if (book.version && book.version > 0) return;
  // if (book.cover_kind && book.cover_kind != "fallback") return
  if (book.kind != "pdf") return;
  const bytes = await blob.bytes();
  const cover = Array.from(bytes);
  await updateBook(
    {
      id: book.id,
      cover,
    },
    store
  );
}
export async function getStore() {
  const store = await load("store.json", {
    autoSave: true,
    defaults: { books: [] },
  });
  return store;
}

export async function deleteBook(book: BookData, storeParam?: Store) {
  const store = storeParam || (await getStore());
  const books = await store.get<BookData[]>("books");
  if (!books) {
    return;
  }
  const index = books.findIndex((b) => b.id === book.id);
  if (index === -1) {
    return;
  }
  books.splice(index, 1);
  await store.set("books", books);
}
export async function updateBook(
  bookSlice: Partial<BookData> & { id: string },
  storeParam?: Store
) {
  const store = storeParam || (await getStore());

  const book = await getBook(bookSlice.id, store);
  if (!book) return;
  await storeBook({ ...book, ...bookSlice }, storeParam);
}



