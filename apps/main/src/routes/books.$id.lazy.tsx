import Loader from "@components/Loader";
import { useQuery } from "@tanstack/react-query";
import { createLazyFileRoute } from "@tanstack/react-router";

import React, { useEffect } from "react";
import { EpubView } from "@components/epub";
import { PdfView } from "@components/pdf/components/pdf";
import { motion } from "framer-motion";
import { useSetAtom } from "jotai";
import {
  bookAtom,
  BookNavigationState,
  bookNavigationStateAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { convertFileSrc } from "@tauri-apps/api/core";
import { getBook } from "@/generated";
export const Route = createLazyFileRoute("/books/$id")({
  component: () => <BookView />,
});

function BookView(): React.JSX.Element {
  const { id } = Route.useParams() as { id: string };
  const setBook = useSetAtom(bookAtom);

  const {
    isPending,
    error,
    data: book,
    isError,
  } = useQuery({
    queryKey: ["book", id],
    queryFn: async () => {
      const book = await getBook({ bookId: Number(id) });
      if (!book) {
        throw new Error("Book not found");
      }

      setBook({
        id: book.id,
        kind: book.kind,
        cover: book.cover,
        title: book.title,
        author: book.author,
        publisher: book.publisher,
        filepath: book.filepath,
        location: book.location,
        version: book.version,
        coverKind: book.coverKind,
      });
      return book;
    },
  });
  // COntrols the lifecycle of the book navigation state
  const setBookNavigationState = useSetAtom(bookNavigationStateAtom);
  useEffect(() => {
    setBookNavigationState(BookNavigationState.Navigated);
    return () => {
      setBookNavigationState(BookNavigationState.Idle);
      setBook(null);
    };
  }, []);

  // Create stable debounced function that uses the latest mutation

  if (isError)
    return (
      <div className="w-full h-full place-items-center grid">
        {" "}
        {error.message}
      </div>
    );
  if (isPending)
    return (
      <div className="w-full h-screen place-items-center grid">
        <Loader />
      </div>
    );

  return (
    <motion.div layout className="">
      {book?.kind === "pdf" && (
        <PdfView
          filepath={convertFileSrc(book.filepath)}
          key={book.id.toString()}
          book={book}
        />
      )}
      {book?.kind === "epub" && <EpubView key={book.id} book={book} />}
    </motion.div>
  );
}
