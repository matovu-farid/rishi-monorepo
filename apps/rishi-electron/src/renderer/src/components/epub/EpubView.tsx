import { useState, useCallback, useEffect, useRef } from "react";
import { ReactReader } from "react-reader";
import { ArrowLeft, List } from "lucide-react";
import { Link } from "@tanstack/react-router";
import type { NavItem, Rendition } from "epubjs";
import { useEpubStore } from "@/stores/epubStore";
import { updateBookLocation, type Book } from "@/lib/api";
import Loader from "../Loader";
import { TableOfContents, type TocItem } from "../react-reader/TableOfContents";

interface Props {
  book: Book;
}

export default function EpubView({ book }: Props) {
  const [location, setLocation] = useState<string | number>(book.currentCfi || 0);
  const setRendition = useEpubStore((s) => s.setRendition);
  const setBookId = useEpubStore((s) => s.setBookId);
  const setCurrentEpubLocation = useEpubStore((s) => s.setCurrentEpubLocation);

  // Load EPUB as ArrayBuffer via IPC - epub.js/react-reader accepts ArrayBuffer directly
  const [epubData, setEpubData] = useState<ArrayBuffer | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  // TOC state
  const [toc, setToc] = useState<NavItem[]>([]);
  const [tocOpen, setTocOpen] = useState(false);

  // Rendition ref for imperative navigation
  const renditionRef = useRef<Rendition | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoadError(null);
    setEpubData(null);

    console.log("[epub] Loading file:", book.filepath);

    window.electron
      .readFile(book.filepath)
      .then((data) => {
        if (cancelled) return;
        // data is ArrayBuffer from IPC
        const buf = data instanceof ArrayBuffer ? data : new Uint8Array(data as any).buffer;
        console.log("[epub] Loaded, byteLength:", buf.byteLength);
        setEpubData(buf);
      })
      .catch((err) => {
        if (!cancelled) {
          console.error("[epub] Failed to load file:", err);
          setLoadError(err instanceof Error ? err.message : String(err));
        }
      });

    return () => {
      cancelled = true;
    };
  }, [book.filepath]);

  const locationChanged = useCallback(
    (epubcfi: string) => {
      setLocation(epubcfi);
      setCurrentEpubLocation(epubcfi);
      void updateBookLocation({ bookId: book.id, newLocation: epubcfi });
    },
    [book.id, setCurrentEpubLocation],
  );

  const getRendition = useCallback(
    (rendition: Rendition) => {
      renditionRef.current = rendition;
      setRendition(rendition);
      setBookId(book.id.toString());
    },
    [book.id, setRendition, setBookId],
  );

  // TOC navigation
  const handleTocNavigate = useCallback(
    (href: string) => {
      if (renditionRef.current) {
        renditionRef.current.display(href);
      }
    },
    [],
  );

  if (loadError) {
    return (
      <div className="flex flex-col h-screen items-center justify-center">
        <p className="text-red-500">Failed to load EPUB: {loadError}</p>
      </div>
    );
  }

  if (!epubData) {
    return (
      <div className="flex flex-col h-screen items-center justify-center">
        <Loader />
      </div>
    );
  }

  return (
    <div className="flex flex-col h-screen">
      <div
        data-electron-drag-region
        className="flex items-center gap-2 px-4 py-2 border-b border-gray-200"
      >
        <Link
          to="/"
          className="p-2 hover:bg-gray-100 rounded-lg"
          onClick={() => {
            try {
              localStorage.setItem("lastReadBookId", book.id.toString());
              window.dispatchEvent(new Event("lastReadBookChanged"));
            } catch {
              /* ignore */
            }
          }}
        >
          <ArrowLeft size={20} />
        </Link>
        <button
          className="p-2 hover:bg-gray-100 rounded-lg cursor-pointer"
          onClick={() => setTocOpen((prev) => !prev)}
          aria-label="Toggle table of contents"
        >
          <List size={20} />
        </button>
        <span className="text-sm font-medium truncate flex-1">{book.title}</span>
      </div>

      <div style={{ position: "relative", height: "calc(100vh - 50px)", overflow: "hidden" }}>
        <ReactReader
          url={epubData}
          location={location}
          locationChanged={locationChanged}
          getRendition={getRendition}
          tocChanged={(newToc) => setToc(newToc)}
          epubOptions={{ flow: "paginated", spread: "none" }}
        />
      </div>

      {/* Table of Contents sidebar */}
      <TableOfContents
        toc={toc as TocItem[]}
        onNavigate={handleTocNavigate}
        isOpen={tocOpen}
        onClose={() => setTocOpen(false)}
      />
    </div>
  );
}
