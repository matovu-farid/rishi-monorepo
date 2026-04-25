import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import Loader from "./Loader";
import { Link, useNavigate } from "@tanstack/react-router";
import { toast } from "react-toastify";
import { Button } from "./ui/Button";
import { Trash2, Plus, Search } from "lucide-react";
// chooseFiles moved into BookDiscoveryModal
import {
  Book,
  deleteBook,
  getBookData,
  getBooks,
  getDjvuData,
  getMobiData,
  getPdfData,
  saveBook,
} from "@/lib/api";
import { copyBookToAppData } from "@/modules/books";
import { prefetchRealtimeKey } from "@/modules/realtime";
import { prefetchTTSForBooks } from "@/modules/ttsPrefetch";
import { hashBookFile, uploadBookFile } from "@/modules/file-sync";
import { motion, AnimatePresence } from "framer-motion";
import { useEffect, useMemo, useState, useCallback } from "react";
import { useDropzone } from "react-dropzone";
import { usePdfStore } from "@/stores/pdfStore";
import { LoginButton } from "./LoginButton";
import { UpdateMenu } from "./UpdateMenu";
import { BookDiscoveryModal } from "./BookDiscoveryModal";
import { HelpMenu } from "./HelpMenu";

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${Math.round(ms / 1000)}s`)), ms);
    promise.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); }
    );
  });
}

const COPY_TIMEOUT = 2 * 60 * 1000;
const EXTRACT_TIMEOUT = 60 * 1000;
const SAVE_TIMEOUT = 30 * 1000;

function bytesToBlobUrl(bytes: number[]): string | null {
  if (!bytes || bytes.length === 0) return null;
  const uint8Array = new Uint8Array(bytes);
  let mimeType = "image/jpeg";
  if (uint8Array.length >= 8) {
    if (uint8Array[0] === 0x89 && uint8Array[1] === 0x50) mimeType = "image/png";
    else if (uint8Array[0] === 0xff && uint8Array[1] === 0xd8) mimeType = "image/jpeg";
    else if (uint8Array[0] === 0x47 && uint8Array[1] === 0x49) mimeType = "image/gif";
    else if (uint8Array[0] === 0x52 && uint8Array[1] === 0x49 && uint8Array[8] === 0x57) mimeType = "image/webp";
  }
  return URL.createObjectURL(new Blob([uint8Array], { type: mimeType }));
}

function BookCoverImage({ book }: { book: Book }) {
  const [coverUrl, setCoverUrl] = useState<string | null>(null);

  useEffect(() => {
    const url = bytesToBlobUrl(book.cover);
    setCoverUrl(url);
    return () => { if (url) URL.revokeObjectURL(url); };
  }, [book.id]);

  if (!coverUrl) {
    // Placeholder cover for books without cover images
    return (
      <div className="w-[200px] h-[280px] bg-gradient-to-br from-gray-100 to-gray-200 rounded-lg flex flex-col items-center justify-center shadow-lg p-4">
        <div className="text-4xl mb-2 opacity-30">📖</div>
        <p className="text-xs text-gray-500 text-center font-medium truncate w-full">{book.title}</p>
        <p className="text-xs text-gray-400 text-center truncate w-full">{book.author}</p>
      </div>
    );
  }

  return <img className="object-fill shadow-3xl drop-shadow-lg rounded-lg" src={coverUrl} width={200} height={280} alt={book.title} />;
}

export default function FileComponent(): React.JSX.Element {
  const setAllBooks = usePdfStore((s) => s.setAllBooks);
  const removeBook = usePdfStore((s) => s.removeBook);
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [newBookId, setNewBookId] = useState<string | null>(null);
  const [discoveryOpen, setDiscoveryOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; book: Book } | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [lastReadBookId, setLastReadBookId] = useState<string | null>(null);

  const navigateToNewBook = useCallback((bookId: string) => {
    void navigate({ to: "/books/$id", params: { id: bookId } });
  }, [navigate]);

  useEffect(() => { if (newBookId) navigateToNewBook(newBookId); }, [newBookId, navigateToNewBook]);

  const { isPending, error, data: books, isError } = useQuery({
    queryKey: ["books"],
    queryFn: async () => {
      prefetchRealtimeKey();
      const books = await getBooks();
      const pdfIds = books.filter((b) => b.kind === "pdf").map((b) => b.id);
      setAllBooks(pdfIds);
      books.forEach((book) => {
        void queryClient.prefetchQuery({ queryKey: ["book", book.id.toString()], queryFn: () => book });
      });
      void prefetchTTSForBooks(books);
      return books;
    },
  });

  const deleteBookMutation = useMutation({
    mutationKey: ["deleteBook"],
    mutationFn: async ({ book }: { book: Book }) => {
      await deleteBook({ bookId: book.id });
      removeBook(book.id);
    },
    onError: (err) => { console.error("Error deleting book:", err); toast.error("Can't remove book"); },
    onSuccess: () => { void queryClient.invalidateQueries({ queryKey: ["books"] }); },
  });

  const importBook = async (filePath: string) => {
    try {
      const ext = filePath.split(".").pop()?.toLowerCase();
      const bookPath = await withTimeout(copyBookToAppData(filePath), COPY_TIMEOUT, "Copying file");

      let bookData;
      if (ext === "epub") bookData = await withTimeout(getBookData({ path: bookPath }), EXTRACT_TIMEOUT, "Extracting metadata");
      else if (ext === "pdf") bookData = await withTimeout(getPdfData({ path: bookPath }), EXTRACT_TIMEOUT, "Extracting metadata");
      else if (ext === "mobi" || ext === "azw3") bookData = await withTimeout(getMobiData({ path: bookPath }), EXTRACT_TIMEOUT, "Extracting metadata");
      else if (ext === "djvu") bookData = await withTimeout(getDjvuData({ path: bookPath }), EXTRACT_TIMEOUT, "Extracting metadata");
      else { toast.error(`Unsupported format: .${ext}`); return; }

      const book = await withTimeout(
        saveBook({
          book: {
            coverKind: bookData.coverKind || "", title: bookData.title || "", author: bookData.author || "",
            publisher: bookData.publisher || "", filepath: bookPath, location: ext === "mobi" ? "0" : "1",
            version: 0, kind: bookData.kind, cover: bookData.cover,
          },
        }),
        SAVE_TIMEOUT, "Saving to library"
      );

      // Hash + upload (non-blocking)
      try {
        const fileHash = await hashBookFile(bookPath);
        const formatForUpload = (ext === "azw3" ? "mobi" : ext) as "epub" | "pdf" | "mobi" | "djvu";
        const { r2Key } = await uploadBookFile(bookPath, fileHash, formatForUpload || "epub");
        await window.electron.dbRun(
          "UPDATE books SET file_hash = ?, file_r2_key = ?, is_dirty = 1 WHERE id = ?",
          [fileHash, r2Key, book.id]
        );
      } catch (err) {
        console.warn("[file-sync] Upload failed, will retry:", err);
      }

      await queryClient.invalidateQueries({ queryKey: ["books"] });
      setNewBookId(null);
      setTimeout(() => setNewBookId(book.id.toString()), 0);
    } catch (err) {
      console.error("Error importing:", err);
      toast.error(err instanceof Error ? err.message : "Import failed");
    }
  };

  const processFilePaths = (filePaths: string[]) => {
    filePaths.forEach((fp) => void importBook(fp));
  };

  // React Dropzone for drag-and-drop (replaces Tauri drag-drop)
  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    noClick: true,
    accept: {
      "application/epub+zip": [".epub"],
      "application/pdf": [".pdf"],
      "application/x-mobipocket-ebook": [".mobi", ".azw3"],
      "image/vnd.djvu": [".djvu"],
    },
    onDrop: (files) => {
      // In Electron, dropped files have .path
      const paths = files.map((f) => (f as any).path).filter(Boolean);
      processFilePaths(paths);
    },
  });

  useEffect(() => {
    const handleClick = () => setContextMenu(null);
    document.addEventListener("click", handleClick);
    return () => document.removeEventListener("click", handleClick);
  }, []);

  useEffect(() => {
    try { const stored = localStorage.getItem("lastReadBookId"); if (stored) setLastReadBookId(stored); } catch {}
  }, []);

  useEffect(() => {
    const handler = () => {
      try { setLastReadBookId(localStorage.getItem("lastReadBookId")); } catch {}
    };
    window.addEventListener("lastReadBookChanged", handler);
    return () => window.removeEventListener("lastReadBookChanged", handler);
  }, []);

  const filteredBooks = useMemo(() => {
    if (!books) return [];
    if (!searchQuery.trim()) return books;
    const q = searchQuery.toLowerCase();
    return books.filter((b) => b.title.toLowerCase().includes(q) || b.author.toLowerCase().includes(q));
  }, [books, searchQuery]);

  const lastReadBook = useMemo(() => {
    if (!lastReadBookId || !books) return null;
    return books.find((b) => b.id.toString() === lastReadBookId) ?? null;
  }, [lastReadBookId, books]);

  if (isError) return <div className="w-full h-full place-items-center grid">{error.message}</div>;
  if (isPending) return <div className="w-full h-full place-items-center grid"><Loader /></div>;

  return (
    <div {...getRootProps()} className="w-full h-full overflow-hidden">
      <input {...getInputProps()} />
      <div data-electron-drag-region className="px-4 pt-10 pb-2 flex items-center gap-2">
        <div className="relative flex-1 max-w-xs">
          <Search size={16} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-gray-400 pointer-events-none" />
          <input type="text" placeholder="Search library..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full bg-gray-100 text-gray-900 placeholder-gray-400 text-sm rounded-lg pl-8 pr-3 py-1.5 border-none focus:outline-none focus:ring-1 focus:ring-gray-300" />
        </div>
        <div className="flex-1" />
        <div data-tour="import-books" className="flex items-center gap-1">
          <Button variant="ghost" className="cursor-pointer" startIcon={<Plus size={20} />} onClick={() => setDiscoveryOpen(true)}>Add Book</Button>
        </div>
        <LoginButton />
        <UpdateMenu />
        <HelpMenu />
      </div>

      {lastReadBook && (
        <div className="px-5 mb-4">
          <p className="text-xs text-gray-400 uppercase tracking-wider mb-2">Reading Now</p>
          <Link to="/books/$id" params={{ id: lastReadBook.id.toString() }} className="flex items-center gap-4 bg-gray-50 rounded-xl p-3 hover:bg-gray-100 transition-colors">
            <div className="w-16 shrink-0"><BookCoverImage book={lastReadBook} /></div>
            <div className="min-w-0">
              <p className="text-sm font-medium text-gray-900 truncate">{lastReadBook.title}</p>
              <p className="text-xs text-gray-500 truncate">{lastReadBook.author}</p>
            </div>
          </Link>
        </div>
      )}

      <motion.div data-tour="book-grid" layout initial="animate" animate="animate"
        style={filteredBooks.length > 0 ? { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gridAutoFlow: "row" } : {}}
        className={filteredBooks.length > 0 ? "w-full p-5 gap-[30px] place-items-baseline cursor-pointer" : "grid place-items-center gap-3 rounded-3xl w-[50vw] h-[50vh] p-5 mx-auto"}>
        {isDragActive && (!books || books.length === 0) ? (
          <p>Drop the files here ...</p>
        ) : filteredBooks.length > 0 ? (
          <AnimatePresence>
            {filteredBooks.map((book) => (
              <motion.div key={book.id} initial={{ opacity: 0.5, scale: 0.7 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0.5, scale: 0.7 }}
                className="p-2 grid relative transition-transform duration-200 ease-out hover:scale-[1.03]"
                onContextMenu={(e) => { e.preventDefault(); setContextMenu({ x: e.clientX, y: e.clientY, book }); }}>
                <Link to="/books/$id" params={{ id: book.id.toString() }} className="rounded-3xl bg-transparent">
                  <BookCoverImage book={book} />
                </Link>
                <p className="text-xs font-medium text-gray-900 truncate mt-1 max-w-[200px]">{book.title}</p>
                <p className="text-xs text-gray-500 truncate max-w-[200px]">{book.author}</p>
              </motion.div>
            ))}
          </AnimatePresence>
        ) : (
          <div className="text-center">
            <p className="mb-4">No books yet. Add your first book!</p>
            <p className="text-sm text-gray-500">You can also drag and drop EPUB, PDF, MOBI, or DJVU files here</p>
          </div>
        )}
      </motion.div>

      {contextMenu && (
        <div className="fixed z-50 bg-white rounded-lg shadow-lg border border-gray-200 py-1 min-w-[140px]"
          style={{ top: contextMenu.y, left: contextMenu.x }}>
          <button className="flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 w-full text-left rounded"
            onClick={() => { deleteBookMutation.mutate({ book: contextMenu.book }); setContextMenu(null); }}>
            <Trash2 size={16} /> Delete
          </button>
        </div>
      )}
      <BookDiscoveryModal open={discoveryOpen} onClose={() => setDiscoveryOpen(false)} onImport={(fp) => processFilePaths([fp])} onImportFiles={processFilePaths} />
    </div>
  );
}
