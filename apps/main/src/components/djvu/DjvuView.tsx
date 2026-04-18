import { useCallback, useEffect, useRef, useState } from "react";
import { useEpubStore } from "@/stores/epubStore";
import {
  getDjvuPage,
  getDjvuPageCount,
  getDjvuPageText,
  hasSavedEpubData,
  updateBookLocation,
} from "@/generated";
import type { Book } from "@/generated";
import { BackButton } from "@components/BackButton";
import TTSControls from "@components/TTSControls";
import { IconButton } from "@components/ui/IconButton";
import { ChevronLeft, ChevronRight, Menu as MenuIcon, MessageSquare, ZoomIn, ZoomOut } from "lucide-react";
import { eventBus, EventBusEvent } from "@/utils/bus";
import type { ParagraphWithIndex } from "@/utils/bus";
import { processEpubJob } from "@/modules/process_epub";
import type { PageDataInsertable } from "@/modules/kysley";
import { ChatPanel } from "@/components/chat/ChatPanel";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { db } from "@/modules/kysley";
import { stringToNumberID } from "@components/lib/utils";
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@components/components/ui/sheet";

const PAGE_CACHE_SIZE = 5;
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 3.0;
const ZOOM_STEP = 0.25;
const DEFAULT_DPI = 150;

interface PageCache {
  urls: Map<number, string>;
  order: number[];
}

export function DjvuView({ book }: { book: Book }) {
  const [pageCount, setPageCount] = useState<number>(0);
  const [currentPage, setCurrentPage] = useState<number>(() => {
    const parsed = parseInt(book.location, 10);
    return parsed > 0 ? parsed : 1;
  });
  const [zoom, setZoom] = useState<number>(1.0);
  const [loading, setLoading] = useState<boolean>(true);
  const [currentBlobUrl, setCurrentBlobUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const cacheRef = useRef<PageCache>({ urls: new Map(), order: [] });
  const mountedRef = useRef(true);
  const embeddingsProcessedRef = useRef(false);
  const [chatPanelOpen, setChatPanelOpen] = useState(false);
  const [tocOpen, setTocOpen] = useState(false);
  const [tocTab, setTocTab] = useState<"contents" | "bookmarks">("contents");
  const { requireAuth, AuthDialog } = useRequireAuth();
  const bookSyncIdRef = useRef<string | null>(null);

  // Set bookId for voice chat
  const setBookId = useEpubStore((s) => s.setBookId);
  useEffect(() => {
    setBookId(book.id.toString());
  }, [book.id, setBookId]);

  // Look up the book's sync_id for chat
  useEffect(() => {
    void db.selectFrom("books")
      .select(["sync_id"])
      .where("id", "=", book.id)
      .executeTakeFirst()
      .then((row) => {
        bookSyncIdRef.current = row?.sync_id ?? null;
      });
  }, [book.id]);

  // Load total page count on mount
  useEffect(() => {
    mountedRef.current = true;
    getDjvuPageCount({ path: book.filepath })
      .then((count) => {
        if (mountedRef.current) {
          setPageCount(count);
        }
      })
      .catch((err) => {
        if (mountedRef.current) {
          setError(`Failed to load DJVU: ${String(err)}`);
        }
      });

    return () => {
      mountedRef.current = false;
      // Revoke all cached blob URLs on unmount
      const cache = cacheRef.current;
      for (const url of cache.urls.values()) {
        URL.revokeObjectURL(url);
      }
      cache.urls.clear();
      cache.order = [];
    };
  }, [book.filepath]);

  const fetchPage = useCallback(
    async (pageNumber: number): Promise<string | null> => {
      const cache = cacheRef.current;

      // Return cached URL if available
      const cached = cache.urls.get(pageNumber);
      if (cached) {
        return cached;
      }

      try {
        const bytes = await getDjvuPage({
          path: book.filepath,
          pageNumber,
          dpi: DEFAULT_DPI,
        });
        const uint8 = new Uint8Array(bytes);
        const blob = new Blob([uint8], { type: "image/png" });
        const url = URL.createObjectURL(blob);

        // Add to cache
        cache.urls.set(pageNumber, url);
        cache.order.push(pageNumber);

        // Evict oldest entries if cache exceeds size
        while (cache.order.length > PAGE_CACHE_SIZE) {
          const evicted = cache.order.shift()!;
          const evictedUrl = cache.urls.get(evicted);
          if (evictedUrl) {
            URL.revokeObjectURL(evictedUrl);
            cache.urls.delete(evicted);
          }
        }

        return url;
      } catch (err) {
        console.error(`Failed to fetch DJVU page ${pageNumber}:`, err);
        return null;
      }
    },
    [book.filepath]
  );

  // Load current page and prefetch neighbors
  useEffect(() => {
    if (pageCount === 0) return;

    let cancelled = false;
    setLoading(true);
    setError(null);

    void fetchPage(currentPage).then((url) => {
      if (cancelled || !mountedRef.current) return;
      if (url) {
        setCurrentBlobUrl(url);
      } else {
        setError(`Failed to load page ${currentPage}`);
      }
      setLoading(false);
    });

    // Prefetch neighbors in background
    if (currentPage > 1) {
      void fetchPage(currentPage - 1);
    }
    if (currentPage < pageCount) {
      void fetchPage(currentPage + 1);
    }

    return () => {
      cancelled = true;
    };
  }, [currentPage, pageCount, fetchPage]);

  // Persist reading position
  useEffect(() => {
    if (pageCount === 0) return;
    updateBookLocation({
      bookId: book.id,
      newLocation: String(currentPage),
    }).catch((err) => {
      console.error("Failed to persist reading position:", err);
    });
  }, [currentPage, book.id, pageCount]);

  const goToPage = useCallback(
    (page: number) => {
      const clamped = Math.max(1, Math.min(page, pageCount));
      setCurrentPage(clamped);
    },
    [pageCount]
  );

  const goPrev = useCallback(() => goToPage(currentPage - 1), [currentPage, goToPage]);
  const goNext = useCallback(() => goToPage(currentPage + 1), [currentPage, goToPage]);

  const zoomIn = useCallback(() => {
    setZoom((z) => Math.min(MAX_ZOOM, +(z + ZOOM_STEP).toFixed(2)));
  }, []);

  const zoomOut = useCallback(() => {
    setZoom((z) => Math.max(MIN_ZOOM, +(z - ZOOM_STEP).toFixed(2)));
  }, []);

  // Keyboard navigation
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      // Ignore if user is typing in an input
      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      ) {
        return;
      }

      switch (e.key) {
        case "ArrowLeft":
          e.preventDefault();
          goPrev();
          break;
        case "ArrowRight":
          e.preventDefault();
          goNext();
          break;
        case "+":
        case "=":
          e.preventDefault();
          zoomIn();
          break;
        case "-":
          e.preventDefault();
          zoomOut();
          break;
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [goPrev, goNext, zoomIn, zoomOut]);

  // Publish paragraphs to event bus for TTS
  useEffect(() => {
    if (pageCount === 0) return;

    // Current page paragraphs
    getDjvuPageText({ path: book.filepath, pageNumber: currentPage })
      .then((texts) => {
        const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
          text,
          index: `djvu-${currentPage}-${i}`,
        }));
        eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);
      })
      .catch((err) => console.warn("[DjvuView] failed to get text for TTS:", err));

    // Prefetch next page paragraphs
    if (currentPage < pageCount) {
      getDjvuPageText({ path: book.filepath, pageNumber: currentPage + 1 })
        .then((texts) => {
          const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
            text,
            index: `djvu-${currentPage + 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, paragraphs);
        })
        .catch((err) => console.warn("[DjvuView] failed to prefetch next page:", err));
    } else {
      eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, []);
    }

    // Prefetch previous page paragraphs
    if (currentPage > 1) {
      getDjvuPageText({ path: book.filepath, pageNumber: currentPage - 1 })
        .then((texts) => {
          const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
            text,
            index: `djvu-${currentPage - 1}-${i}`,
          }));
          eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, paragraphs);
        })
        .catch((err) => console.warn("[DjvuView] failed to prefetch prev page:", err));
    } else {
      eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, []);
    }
  }, [book.filepath, currentPage, pageCount]);

  // Handle page-turn events from Player (TTS exhausted current page)
  useEffect(() => {
    const handleNextEmptied = () => {
      setCurrentPage((prev) => Math.min(prev + 1, pageCount));
    };
    const handlePrevEmptied = () => {
      setCurrentPage((prev) => Math.max(prev - 1, 1));
    };

    eventBus.on(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmptied);
    eventBus.on(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmptied);

    return () => {
      eventBus.off(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmptied);
      eventBus.off(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmptied);
    };
  }, [pageCount]);

  // Generate embeddings on first open (for AI chat)
  useEffect(() => {
    if (pageCount === 0 || embeddingsProcessedRef.current) return;
    embeddingsProcessedRef.current = true;

    void (async () => {
      try {
        const alreadySaved = await hasSavedEpubData({ bookId: book.id });
        if (alreadySaved) return;

        const allPageData: PageDataInsertable[] = [];
        for (let page = 1; page <= pageCount; page++) {
          const texts = await getDjvuPageText({ path: book.filepath, pageNumber: page });
          const combined = texts.join("\n").trim();
          if (combined.length > 0) {
            allPageData.push({
              id: stringToNumberID(`${book.id}-djvu-${page}`),
              pageNumber: page,
              bookId: book.id,
              data: combined,
            });
          }
        }

        if (allPageData.length > 0) {
          await processEpubJob(book.id, allPageData);
        }
      } catch (err) {
        console.warn("[DjvuView] failed to generate embeddings:", err);
      }
    })();
  }, [book.id, book.filepath, pageCount]);

  return (
    <div className="relative h-screen w-full flex flex-col bg-gray-900">
      {/* Top bar */}
      <div className="fixed top-0 left-0 right-0 z-50 bg-transparent">
        <div className="flex items-center justify-end gap-2 px-4 pt-5">
          <IconButton onClick={() => setTocOpen(true)} className="hover:bg-transparent border-none">
            <MenuIcon size={20} />
          </IconButton>
          <BookmarkButton
            bookSyncId={bookSyncIdRef.current ?? ""}
            location={String(currentPage)}
            label={`Page ${currentPage}`}
            className="hover:bg-transparent border-none"
          />
          <button
            onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
            className="p-2 rounded-md text-white hover:bg-white/10"
            aria-label="Open chat panel"
          >
            <MessageSquare size={20} />
          </button>
          <BackButton />
        </div>
      </div>

      {/* Main scrollable area */}
      <div className="flex-1 overflow-auto flex items-start justify-center pt-16 pb-24">
        {error && (
          <div className="text-red-400 text-center mt-20 px-4">
            <p>{error}</p>
          </div>
        )}

        {loading && !error && (
          <div className="text-white/60 text-center mt-20">
            <div className="animate-spin inline-block w-6 h-6 border-2 border-white/30 border-t-white rounded-full" />
            <p className="mt-2 text-sm">Loading page {currentPage}...</p>
          </div>
        )}

        {!loading && currentBlobUrl && !error && (
          <div
            className="transition-transform duration-150 origin-top"
            style={{ transform: `scale(${zoom})` }}
          >
            <img
              src={currentBlobUrl}
              alt={`Page ${currentPage} of ${book.title}`}
              className="max-w-full shadow-2xl"
              draggable={false}
            />
          </div>
        )}
      </div>

      {/* Bottom navigation bar */}
      <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50">
        <div className="flex items-center gap-2 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg shadow-lg border border-white/10">
          {/* Zoom controls */}
          <IconButton
            onClick={zoomOut}
            disabled={zoom <= MIN_ZOOM}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Zoom out"
          >
            <ZoomOut size={18} />
          </IconButton>

          <span className="text-white/80 text-sm font-mono min-w-[3.5rem] text-center select-none">
            {Math.round(zoom * 100)}%
          </span>

          <IconButton
            onClick={zoomIn}
            disabled={zoom >= MAX_ZOOM}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Zoom in"
          >
            <ZoomIn size={18} />
          </IconButton>

          {/* Divider */}
          <div className="w-px h-6 bg-white/20 mx-1" />

          {/* Page navigation */}
          <IconButton
            onClick={goPrev}
            disabled={currentPage <= 1}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Previous page"
          >
            <ChevronLeft size={20} />
          </IconButton>

          <span className="text-white/80 text-sm font-mono min-w-[4rem] text-center select-none">
            {currentPage} / {pageCount}
          </span>

          <IconButton
            onClick={goNext}
            disabled={currentPage >= pageCount}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Next page"
          >
            <ChevronRight size={20} />
          </IconButton>
        </div>
      </div>

      {/* TTS Controls */}
      <TTSControls key={book.id.toString()} bookId={book.id.toString()} />

      {AuthDialog}

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncIdRef.current ?? ""}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />

      {/* Navigation / Bookmarks Sidebar */}
      <Sheet open={tocOpen} onOpenChange={setTocOpen}>
        <SheetContent side="left" className="w-[300px] sm:w-[400px] p-0 bg-white border-gray-200">
          <SheetHeader className="p-4 border-b sticky top-0 z-10 border-gray-200 bg-white">
            <SheetTitle>Navigation</SheetTitle>
          </SheetHeader>
          <div className="flex border-b border-gray-200">
            <button
              onClick={() => setTocTab("contents")}
              className={`flex-1 px-4 py-2 text-sm font-medium transition-colors ${
                tocTab === "contents"
                  ? "border-b-2 border-blue-500 text-blue-600"
                  : "text-gray-500 hover:text-gray-700"
              }`}
            >
              Contents
            </button>
            <button
              onClick={() => setTocTab("bookmarks")}
              className={`flex-1 px-4 py-2 text-sm font-medium transition-colors ${
                tocTab === "bookmarks"
                  ? "border-b-2 border-red-500 text-red-600"
                  : "text-gray-500 hover:text-gray-700"
              }`}
            >
              Bookmarks
            </button>
          </div>
          {tocTab === "contents" ? (
            <div className="p-4 text-gray-400 text-sm text-center">
              Page {currentPage} of {pageCount}
            </div>
          ) : (
            <BookmarksList
              bookSyncId={bookSyncIdRef.current ?? ""}
              onNavigate={(location) => {
                const page = parseInt(location, 10);
                if (page > 0) {
                  setCurrentPage(page);
                  setTocOpen(false);
                }
              }}
            />
          )}
        </SheetContent>
      </Sheet>
    </div>
  );
}
