import { useCallback, useEffect, useRef, useState } from "react";
import {
  getDjvuPage,
  getDjvuPageCount,
  updateBookLocation,
} from "@/generated";
import type { Book } from "@/generated";
import { BackButton } from "@components/BackButton";
import TTSControls from "@components/TTSControls";
import { IconButton } from "@components/ui/IconButton";
import { ChevronLeft, ChevronRight, ZoomIn, ZoomOut } from "lucide-react";

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

    fetchPage(currentPage).then((url) => {
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

  return (
    <div className="relative h-screen w-full flex flex-col bg-gray-900">
      {/* Top bar */}
      <div className="fixed top-0 left-0 right-0 z-50 bg-transparent">
        <div className="flex items-center justify-end px-4 pt-5">
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
    </div>
  );
}
