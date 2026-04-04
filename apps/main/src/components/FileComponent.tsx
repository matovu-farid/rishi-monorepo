import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import Loader from "./Loader";
import { Link, useNavigate } from "@tanstack/react-router";
import { toast } from "react-toastify";
import { IconButton } from "./ui/IconButton";
import { Button } from "./ui/Button";
import { Trash2, Plus, LogIn } from "lucide-react";
import { chooseFiles } from "@/modules/chooseFiles";
import {
  Book,
  deleteBook,
  getBookData,
  getBooks,
  getPdfData,
  saveBook,
} from "@/generated";
import { copyBookToAppData } from "@/modules/books";
import { useTauriDragDrop } from "./hooks/use-tauri-drag-drop";
import { motion, AnimatePresence } from "framer-motion";
import { atom, useSetAtom } from "jotai";
import { customStore } from "@/stores/jotai";

import {
  pdfsControllerAtom,
  setPageNumberAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { LoginButton } from "./LoginButton";

const newBook = atom<string | null>(null);

const useNavigateToNewBook = () => {
  const navigate = useNavigate();
  function navigateToNewBook(bookId: string) {
    void navigate({
      to: "/books/$id",
      params: { id: bookId },
    });
  }
  customStore.sub(newBook, () => {
    const value = customStore.get(newBook);
    if (value) {
      navigateToNewBook(value);
    }
  });
};

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

function FileDrop(): React.JSX.Element {
  const setPfsController = useSetAtom(pdfsControllerAtom);
  const queryClient = useQueryClient();
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
      setPfsController({ type: "setAll", ids: pdfIds });
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
  useNavigateToNewBook();
  const deleteBookMutation = useMutation({
    mutationKey: ["deleteBook"],
    mutationFn: async ({ book }: { book: Book }) => {
      await deleteBook({ bookId: book.id });
      setPfsController({ type: "remove", id: book.id });
    },

    onError(error) {
      console.error("Error deleting book:", error);
      toast.error("Can't remove book");
    },
    onSuccess() {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
    },
  });

  const setNewBookId = useSetAtom(newBook);

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
      return book;
    },

    onError(error) {
      console.error("Error storing book:", error);
      toast.error("Can't upload book");
    },
    onSuccess: async (bookData) => {
      // Invalidate the books list to refresh it
      await queryClient.invalidateQueries({ queryKey: ["books"] });

      // Reset to null first to ensure the subscription fires even if it's the same ID
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
      return book;
    },

    onError(error) {
      console.error("Error storing PDF:", error);
      toast.error("Can't upload book");
    },
    onSuccess(bookData) {
      void queryClient.invalidateQueries({ queryKey: ["books"] });

      // Reset to null first to ensure the subscription fires even if it's the same ID
      setNewBookId(null);
      // Use setTimeout to ensure the reset happens before setting the new value
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
        }
      });
    }
  };

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
    allowedExtensions: [".epub", ".pdf"],
    onFilesDropped: (filePaths) => {
      processFilePaths(filePaths);
    },
  });
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
    <div className="w-full h-full">
      {/* Add Book Button - always visible at the top */}
      <div className="p-4 flex justify-end">
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<Plus size={20} />}
          onClick={handleChooseFiles}
        >
          Add Book
        </Button>
       <LoginButton />
      </div>

      <motion.div
        layout
        initial="animate"
        animate="animate"
        style={
          books && books.length > 0
            ? {
                display: "grid",
                gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))",
                gridAutoFlow: "row",
              }
            : {}
        }
        className={
          books && books.length > 0
            ? "w-full h-screen p-5 gap-[30px] place-items-baseline cursor-pointer"
            : "grid place-items-center gap-3 rounded-3xl w-[50vw] h-[50vh] p-5 mx-auto"
        }
      >
        {isDragging && (!books || books.length === 0) ? (
          <p>Drop the files here ...</p>
        ) : books && books.length > 0 ? (
          <AnimatePresence>
            {books.map((book) => (
              <motion.div
                key={book.id}
                initial={{ opacity: 0.5, scale: 0.7 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0.5, scale: 0.7 }}
                className="p-2 grid relative"
              >
                <div
                  onClick={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                  }}
                  className="rounded-3xl bg-transparent"
                >
                  <div className="absolute top-0 right-0">
                    <IconButton
                      onClick={() => {
                        deleteBookMutation.mutate({ book });
                      }}
                      color="error"
                      className="bg-white p-0 z-10 drop-shadow cursor-pointer"
                    >
                      <Trash2 size={20} />
                    </IconButton>
                  </div>

                  <Link
                    to="/books/$id"
                    params={{ id: book.id.toString() }}
                    className="rounded-3xl z-5  bg-transparent shadow-none overflow-visible hover:bg-transparent hover:shadow-none"
                  >
                    <img
                      id={book.id.toString() + "cover"}
                      className="object-fill shadow-3xl drop-shadow-lg"
                      src={bytesToBlobUrl(book.cover)}
                      width={200}
                      height={400}
                      alt="cover image"
                    />
                  </Link>
                </div>
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
    </div>
  );
}

export default FileDrop;
