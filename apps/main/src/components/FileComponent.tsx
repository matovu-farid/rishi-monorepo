import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import Loader from "./Loader";
import { Link, useNavigate } from "@tanstack/react-router";
import { toast } from "react-toastify";
import { Button } from "./ui/Button";
import { Trash2, Plus, FolderOpen, Search } from "lucide-react";
import { chooseFiles } from "@/modules/chooseFiles";
import {
  Book,
  deleteBook,
  getBookData,
  getBooks,
  getDjvuData,
  getMobiData,
  getPdfData,
  saveBook,
} from "@/generated";
import { copyBookToAppData } from "@/modules/books";
import { hashBookFile, uploadBookFile } from "@/modules/file-sync";
import { db } from "@/modules/kysley";
import { useTauriDragDrop } from "./hooks/use-tauri-drag-drop";
import { motion, AnimatePresence } from "framer-motion";
import { useEffect, useMemo, useState, useCallback } from "react";

import { usePdfStore } from "@/stores/pdfStore";
import { LoginButton } from "./LoginButton";
import { UpdateMenu } from "./UpdateMenu";
import { BookDiscoveryModal } from "./BookDiscoveryModal";

// Add this helper function
function bytesToBlobUrl(bytes: number[]): string {
  const uint8Array = new Uint8Array(bytes);

  // Detect image format from header bytes
  let mimeType = "image/jpeg"; // default

  if (uint8Array.length >= 8) {
    // Check for PNG signature (89 50 4E 47 0D 0A 1A 0A)
    if (
      uint8Array[0] === 0x89 &&
      uint8Array[1] === 0x50 &&
      uint8Array[2] === 0x4e &&
      uint8Array[3] === 0x47
    ) {
      mimeType = "image/png";
    }
    // Check for JPEG signature (FF D8)
    else if (uint8Array[0] === 0xff && uint8Array[1] === 0xd8) {
      mimeType = "image/jpeg";
    }
    // Check for GIF signature (47 49 46)
    else if (
      uint8Array[0] === 0x47 &&
      uint8Array[1] === 0x49 &&
      uint8Array[2] === 0x46
    ) {
      mimeType = "image/gif";
    }
    // Check for WebP signature (52 49 46 46 ... 57 45 42 50)
    else if (
      uint8Array[0] === 0x52 &&
      uint8Array[1] === 0x49 &&
      uint8Array[2] === 0x46 &&
      uint8Array[3] === 0x46 &&
      uint8Array[8] === 0x57 &&
      uint8Array[9] === 0x45 &&
      uint8Array[10] === 0x42 &&
      uint8Array[11] === 0x50
    ) {
      mimeType = "image/webp";
    }
  }

  const blob = new Blob([uint8Array], { type: mimeType });
  return URL.createObjectURL(blob);
}

/** Memoize blob URL creation and revoke old URLs on change/unmount. */
function useCoverBlobUrl(cover: number[]): string {
  const url = useMemo(() => bytesToBlobUrl(cover), [cover]);

  useEffect(() => {
    return () => {
      URL.revokeObjectURL(url);
    };
  }, [url]);

  return url;
}

function BookCoverImage({ book }: { book: Book }) {
  const coverUrl = useCoverBlobUrl(book.cover);
  return (
    <img
      id={book.id.toString() + "cover"}
      className="object-fill shadow-3xl drop-shadow-lg"
      src={coverUrl}
      width={200}
      height={400}
      alt="cover image"
    />
  );
}

function FileDrop(): React.JSX.Element {
  const setAllBooks = usePdfStore((s) => s.setAllBooks);
  const removeBook = usePdfStore((s) => s.removeBook);
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [newBookId, setNewBookId] = useState<string | null>(null);
  const [discoveryOpen, setDiscoveryOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; book: Book } | null>(null);

  const navigateToNewBook = useCallback((bookId: string) => {
    void navigate({
      to: "/books/$id",
      params: { id: bookId },
    });
  }, [navigate]);

  useEffect(() => {
    if (newBookId) {
      navigateToNewBook(newBookId);
    }
  }, [newBookId, navigateToNewBook]);

  const {
    isPending,
    error,
    data: books,
    isError,
  } = useQuery({
    queryKey: ["books"],
    queryFn: async () => {
      const books = await getBooks();
      const pdfIds = books
        .filter((book) => book.kind === "pdf")
        .map((book) => book.id);
      setAllBooks(pdfIds);
      // prefetch the book data based on ids
      books.forEach((book) => {
        void queryClient.prefetchQuery({
          queryKey: ["book", book.id.toString()],
          queryFn: () => book,
        });
      });
      return books;
    },
  });

  const deleteBookMutation = useMutation({
    mutationKey: ["deleteBook"],
    mutationFn: async ({ book }: { book: Book }) => {
      await deleteBook({ bookId: book.id });
      removeBook(book.id);
    },

    onError(error) {
      console.error("Error deleting book:", error);
      toast.error("Can't remove book");
    },
    onSuccess() {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
    },
  });

  const storeBookDataMutation = useMutation({
    mutationKey: ["getBookData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const epubPath = await copyBookToAppData(filePath);
      const bookData = await getBookData({ path: epubPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: epubPath,
          location: "1",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      // Hash + R2 upload (non-blocking for UX failures, but awaited for data integrity)
      try {
        const fileHash = await hashBookFile(epubPath);
        const { r2Key } = await uploadBookFile(epubPath, fileHash, 'epub');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload epub file, will retry on next sync:', err);
      }

      return book;
    },

    onError(error) {
      console.error("Error storing book:", error);
      toast.error("Can't upload book");
    },
    onSuccess: async (bookData) => {
      // Invalidate the books list to refresh it
      await queryClient.invalidateQueries({ queryKey: ["books"] });

      // Reset to null first to ensure the state change fires even if it's the same ID
      setNewBookId(null);
      // Use setTimeout to ensure the reset happens before setting the new value
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });

  const storePdfMutation = useMutation({
    mutationKey: ["getPdfData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const pdfPath = await copyBookToAppData(filePath);

      const bookData = await getPdfData({ path: pdfPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: pdfPath,
          location: "1",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      // Hash + R2 upload (non-blocking for UX failures, but awaited for data integrity)
      try {
        const fileHash = await hashBookFile(pdfPath);
        const { r2Key } = await uploadBookFile(pdfPath, fileHash, 'pdf');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload pdf file, will retry on next sync:', err);
      }

      return book;
    },

    onError(error) {
      console.error("Error storing PDF:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });

      // Reset to null first to ensure the state change fires even if it's the same ID
      setNewBookId(null);
      // Use setTimeout to ensure the reset happens before setting the new value
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });

  const storeMobiMutation = useMutation({
    mutationKey: ["getMobiData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const mobiPath = await copyBookToAppData(filePath);

      const bookData = await getMobiData({ path: mobiPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: mobiPath,
          location: "0",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      // Hash + R2 upload (non-blocking for UX failures, but awaited for data integrity)
      try {
        const fileHash = await hashBookFile(mobiPath);
        const { r2Key } = await uploadBookFile(mobiPath, fileHash, 'mobi');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload mobi file, will retry on next sync:', err);
      }

      return book;
    },

    onError(error) {
      console.error("Error storing MOBI:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });

      setNewBookId(null);
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });

  const storeDjvuMutation = useMutation({
    mutationKey: ["getDjvuData"],
    mutationFn: async ({ filePath }: { filePath: string }) => {
      const djvuPath = await copyBookToAppData(filePath);

      const bookData = await getDjvuData({ path: djvuPath });
      const book = await saveBook({
        book: {
          coverKind: bookData.coverKind || "",
          title: bookData.title || "",
          author: bookData.author || "",
          publisher: bookData.publisher || "",
          filepath: djvuPath,
          location: "1",
          version: 0,
          kind: bookData.kind,
          cover: bookData.cover,
        },
      });

      // Hash + R2 upload (non-blocking for UX failures, but awaited for data integrity)
      try {
        const fileHash = await hashBookFile(djvuPath);
        const { r2Key } = await uploadBookFile(djvuPath, fileHash, 'djvu');
        await db.updateTable('books')
          .set({
            file_hash: fileHash,
            file_r2_key: r2Key,
            is_dirty: 1,
          })
          .where('id', '=', book.id)
          .execute();
      } catch (err) {
        console.warn('[file-sync] Failed to hash/upload djvu file, will retry on next sync:', err);
      }

      return book;
    },

    onError(error) {
      console.error("Error storing DJVU:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });

      setNewBookId(null);
      setTimeout(() => {
        setNewBookId(bookData.id.toString());
      }, 0);
    },
  });

  // Extract file processing logic to be reusable
  const processFilePaths = (filePaths: string[]) => {
    if (filePaths.length > 0) {
      filePaths.forEach((filePath) => {
        if (filePath.endsWith(".epub")) {
          storeBookDataMutation.mutate({ filePath });
        } else if (filePath.endsWith(".pdf")) {
          storePdfMutation.mutate({ filePath });
        } else if (filePath.endsWith(".mobi") || filePath.endsWith(".azw3")) {
          storeMobiMutation.mutate({ filePath });
        } else if (filePath.endsWith(".djvu")) {
          storeDjvuMutation.mutate({ filePath });
        }
      });
    }
  };

  // Close context menu on outside click
  useEffect(() => {
    const handleClick = () => setContextMenu(null);
    document.addEventListener('click', handleClick);
    return () => document.removeEventListener('click', handleClick);
  }, []);

  // Handle native file picker (recommended approach)
  const handleChooseFiles = async () => {
    try {
      const filePaths: string[] = await chooseFiles();
      processFilePaths(filePaths);
    } catch (error) {
      toast.error("Can't open file picker");
      console.error(error);
    }
  };

  // Handle drag and drop using Tauri native API
  const { isDragging } = useTauriDragDrop({
    allowedExtensions: [".epub", ".pdf", ".mobi", ".azw3", ".djvu"],
    onFilesDropped: (filePaths) => {
      processFilePaths(filePaths);
    },
  });
  const [searchQuery, setSearchQuery] = useState("");
  const [lastReadBookId, setLastReadBookId] = useState<string | null>(null);

  // Load last-read book ID from localStorage
  useEffect(() => {
    const stored = localStorage.getItem("lastReadBookId");
    if (stored) setLastReadBookId(stored);
  }, []);

  // Listen for storage changes (set by BackButton when navigating back)
  useEffect(() => {
    const handler = () => {
      const stored = localStorage.getItem("lastReadBookId");
      setLastReadBookId(stored);
    };
    window.addEventListener("lastReadBookChanged", handler);
    return () => window.removeEventListener("lastReadBookChanged", handler);
  }, []);

  const filteredBooks = useMemo(() => {
    if (!books) return [];
    if (!searchQuery.trim()) return books;
    const q = searchQuery.toLowerCase();
    return books.filter(
      (b) =>
        b.title.toLowerCase().includes(q) ||
        b.author.toLowerCase().includes(q)
    );
  }, [books, searchQuery]);

  const lastReadBook = useMemo(() => {
    if (!lastReadBookId || !books) return null;
    return books.find((b) => b.id.toString() === lastReadBookId) ?? null;
  }, [lastReadBookId, books]);

  if (isError)
    return (
      <div className="w-full h-full place-items-center grid">
        {" "}
        {error.message}
      </div>
    );
  if (isPending)
    return (
      <div className="w-full h-full place-items-center grid">
        <Loader />
      </div>
    );
  return (
    <div className="w-full h-full overflow-hidden">
      {/* Top bar with search + actions, drag region for overlay title bar */}
      <div data-tauri-drag-region className="px-4 pt-10 pb-2 flex items-center gap-2">
        {/* Search input — blends in before the action buttons */}
        <div className="relative flex-1 max-w-xs">
          <Search size={16} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-gray-400 pointer-events-none" />
          <input
            type="text"
            placeholder="Search library…"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full bg-gray-100 text-gray-900 placeholder-gray-400 text-sm rounded-lg pl-8 pr-3 py-1.5 border-none focus:outline-none focus:ring-1 focus:ring-gray-300"
          />
        </div>
        <div className="flex-1" />
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<Plus size={20} />}
          onClick={handleChooseFiles}
        >
          Add Book
        </Button>
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<FolderOpen size={20} />}
          onClick={() => setDiscoveryOpen(true)}
        >
          Import from Computer
        </Button>
        <LoginButton />
        <UpdateMenu />
      </div>

      {/* Reading Now — only shown when user has read a book and pressed back */}
      {lastReadBook && (
        <div className="px-5 mb-4">
          <p className="text-xs text-gray-400 uppercase tracking-wider mb-2">Reading Now</p>
          <Link to="/books/$id" params={{ id: lastReadBook.id.toString() }} className="flex items-center gap-4 bg-gray-50 rounded-xl p-3 hover:bg-gray-100 transition-colors">
            <div className="w-16 shrink-0">
              <BookCoverImage book={lastReadBook} />
            </div>
            <div className="min-w-0">
              <p className="text-sm font-medium text-gray-900 truncate">{lastReadBook.title}</p>
              <p className="text-xs text-gray-500 truncate">{lastReadBook.author}</p>
            </div>
          </Link>
        </div>
      )}

      <motion.div
        layout
        initial="animate"
        animate="animate"
        style={
          filteredBooks.length > 0
            ? {
                display: "grid",
                gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))",
                gridAutoFlow: "row",
              }
            : {}
        }
        className={
          filteredBooks.length > 0
            ? "w-full p-5 gap-[30px] place-items-baseline cursor-pointer"
            : "grid place-items-center gap-3 rounded-3xl w-[50vw] h-[50vh] p-5 mx-auto"
        }
      >
        {isDragging && (!books || books.length === 0) ? (
          <p>Drop the files here ...</p>
        ) : filteredBooks.length > 0 ? (
          <AnimatePresence>
            {filteredBooks.map((book) => (
              <motion.div
                key={book.id}
                initial={{ opacity: 0.5, scale: 0.7 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0.5, scale: 0.7 }}
                className="p-2 grid relative transition-transform duration-200 ease-out hover:scale-[1.03]"
                onContextMenu={(e) => {
                  e.preventDefault();
                  setContextMenu({ x: e.clientX, y: e.clientY, book });
                }}
              >
                <div
                  onClick={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                  }}
                  className="rounded-3xl bg-transparent"
                >
                  <Link
                    to="/books/$id"
                    params={{ id: book.id.toString() }}
                    className="rounded-3xl z-5  bg-transparent shadow-none overflow-visible hover:bg-transparent hover:shadow-none"
                  >
                    <BookCoverImage book={book} />
                  </Link>
                </div>
                <p className="text-xs font-medium text-gray-900 truncate mt-1 max-w-[200px]">{book.title}</p>
                <p className="text-xs text-gray-500 truncate max-w-[200px]">{book.author}</p>
              </motion.div>
            ))}
          </AnimatePresence>
        ) : (
          <div className="text-center">
            <p className="mb-4">No books yet. Add your first book!</p>
            <p className="text-sm text-gray-500">
              You can also drag and drop EPUB or PDF files here
            </p>
          </div>
        )}
      </motion.div>
      {contextMenu && (
        <div
          className="fixed z-50 bg-white rounded-lg shadow-lg border border-gray-200 py-1 min-w-[140px]"
          style={{ top: contextMenu.y, left: contextMenu.x }}
        >
          <button
            className="flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 w-full text-left rounded"
            onClick={() => {
              deleteBookMutation.mutate({ book: contextMenu.book });
              setContextMenu(null);
            }}
          >
            <Trash2 size={16} />
            Delete
          </button>
        </div>
      )}
      <BookDiscoveryModal
        open={discoveryOpen}
        onClose={() => setDiscoveryOpen(false)}
        onImport={(filepath) => {
          processFilePaths([filepath]);
        }}
      />
    </div>
  );
}

export default FileDrop;
