import React, { useEffect, useState, useMemo, useRef } from "react";
import { Loader2, Menu as MenuIcon, LayoutGrid, Mic, MicOff, ChevronLeft } from "lucide-react";
import AIChatOrb from "../../chat/AIChatOrb";
import { ChatPanel } from "@/components/chat/ChatPanel";
import { Document, Outline, pdfjs } from "react-pdf";
import type { DocumentInitParameters } from "pdfjs-dist/types/src/display/api";
import { usePlayerStore } from "@/stores/playerStore";
import { nextPage, previousPage } from "../utils/pageControls";

import { cn } from "@/lib/utils";

// Import required CSS for text and annotation layers
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";

import { usePdfStore, BookNavigationState } from "@/stores/pdfStore";
import { ThumbnailSidebar } from "./thumbnail-sidebar";
import TTSControls from "@/components/tts/TTSControls";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { useUpdateCoverIMage } from "../hooks/useUpdateCoverIMage";
import { useScrolling } from "../hooks/useScrolling";
import { usePdfNavigation } from "../hooks/usePdfNavigation";
import { PageComponent } from "./pdf-page";
import { useSetupMenu } from "../hooks/useSetupMenu";
import { useMutation } from "@tanstack/react-query";
import { toast } from "react-toastify";
import { queryClient } from "@/components/providers";
import { useCurrentPageNumber } from "../hooks/useCurrentPageNumber";
import { PDFDocumentProxy } from "pdfjs-dist";
import { useVirualization } from "../hooks/useVirualization";
import { TextExtractor } from "./text-extractor";
import { updateBookLocation } from "@/lib/api";
import type { Book } from "@/lib/api";
import { Link } from "@tanstack/react-router";
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { ReaderToolbar } from "@/components/reader/ReaderToolbar";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
import { useChatStore } from "@/stores/chatStore";
import { useRequireAuth } from "@/hooks/useRequireAuth";

// Configure PDF.js worker
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  "pdfjs-dist/build/pdf.worker.min.mjs",
  import.meta.url
).toString();

export function PdfView({
  book,
  filepath: _filepath,
}: {
  filepath: string;
  book: Book;
}): React.JSX.Element {
  const [tocOpen, setTocOpen] = useState(false);
  const [bookSyncId, setBookSyncId] = useState<string>("");
  const [chatPanelOpen, setChatPanelOpen] = useState(false);
  const thumbOpen = usePdfStore((s) => s.thumbnailSidebarOpen);
  const setThumbOpen = usePdfStore((s) => s.setThumbnailSidebarOpen);
  const setPdfDocProxy = usePdfStore((s) => s.setPdfDocumentProxy);
  const setBookNavState = usePdfStore((s) => s.setBookNavigationState);

  const setPageNumber = usePdfStore((s) => s.setPageNumber);
  const currentPageNumber = usePdfStore((s) => s.pageNumber);

  const { requireAuth, AuthDialog } = useRequireAuth();
  const isChatting = useChatStore((s) => s.isChatting);
  const setIsChatting = useChatStore((s) => s.setIsChatting);
  const chatStatus = useChatStore((s) => s.chatStatus);

  const handleMicClick = () => {
    requireAuth("voice-input", () => {
      setIsChatting((prev: boolean) => !prev);
    });
  };

  const handleStopChat = () => {
    setIsChatting(false);
  };

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  useScrolling(scrollContainerRef);

  useUpdateCoverIMage(book);
  useSetupMenu();

  const resetParaphState = usePdfStore((s) => s.resetParagraphState);

  useEffect(() => {
    return () => {
      resetParaphState();
      setThumbOpen(false);
      setPdfDocProxy(null);
    };
  }, []);

  // Scoped playerStore subscriptions for PDF page navigation and highlighting.
  useEffect(() => {
    const unsubPage = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      (request) => {
        if (request === "next") nextPage();
        if (request === "prev") previousPage();
        if (request) usePlayerStore.getState().clearPageRequest();
      }
    );

    const unsubActive = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      (paragraph) => {
        if (paragraph) {
          usePdfStore.getState().setIsHighlighting(true);
          usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index);
        }
      }
    );

    const unsubState = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        usePdfStore.getState().setIsHighlighting(state === "playing");
      }
    );

    return () => {
      unsubPage();
      unsubActive();
      unsubState();
    };
  }, []);

  // Fetch the book sync_id via Electron IPC database query
  useEffect(() => {
    void window.electron
      .dbQuery("SELECT sync_id FROM books WHERE id = ?", [book.id])
      .then((rows: any[]) => {
        if (rows.length > 0 && rows[0]?.sync_id) {
          setBookSyncId(rows[0].sync_id);
        }
      })
      .catch((err: unknown) => {
        console.error("Failed to fetch book sync_id:", err);
      });
  }, [book.id]);

  // Configure PDF.js options
  const pdfOptions = useMemo<DocumentInitParameters>(
    () => ({
      cMapPacked: true,
      verbosity: 0,
    }),
    []
  );
  const { isDualPage, pdfWidth, pdfHeight, dualPageWidth, isFullscreen } =
    usePdfNavigation();

  // Setup View submenu in the app menu for PDF view
  const isDualPageRef = useRef(isDualPage);

  // Keep ref in sync with current value
  useEffect(() => {
    isDualPageRef.current = isDualPage;
  }, [isDualPage]);

  const updateBookLocationMutation = useMutation({
    mutationFn: async ({
      bookId,
      location,
    }: {
      bookId: string;
      location: string;
    }) => {
      await updateBookLocation({
        bookId: Number(bookId),
        newLocation: location,
      });
    },

    onError(_error) {
      toast.error("Can not change book page");
    },
    onSuccess() {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
    },
  });

  const pageCount = usePdfStore((s) => s.pageCount);
  const setPageCount = usePdfStore((s) => s.setPageCount);

  function onDocumentLoadSuccess(pdf: PDFDocumentProxy): void {
    setPageCount(pdf.numPages);
    setPdfDocProxy(pdf);
  }

  const pageWidth = isDualPage ? dualPageWidth : pdfWidth;

  const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage);
  const { virtualizer, virtualItems, pageRefs, handlePageRendered } =
    useVirualization(scrollContainerRef, book);

  useCurrentPageNumber(scrollContainerRef, book, virtualizer);

  function onItemClick({ pageNumber: itemPageNumber }: { pageNumber: number }) {
    virtualizer.scrollToIndex(itemPageNumber - 1, {
      align: "start",
      behavior: "smooth",
    });
    setPageNumber(itemPageNumber);
    setTocOpen(false);
    updateBookLocationMutation.mutate({
      bookId: book.id.toString(),
      location: itemPageNumber.toString(),
    });
  }

  function onThumbnailNavigate(pageNumber: number) {
    setBookNavState(BookNavigationState.Idle);
    virtualizer.scrollToIndex(pageNumber - 1, {
      align: "start",
      behavior: "smooth",
    });
    setPageNumber(pageNumber);
    updateBookLocationMutation.mutate({
      bookId: book.id.toString(),
      location: pageNumber.toString(),
    });
  }

  // Inline TOC with bookmarks support (ReaderTOC equivalent for Electron)
  const [tocActiveTab, setTocActiveTab] = useState<"contents" | "bookmarks">("contents");

  // PDF data loading via Electron IPC
  const [pdfData, setPdfData] = useState<{ data: Uint8Array } | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoadError(null);
    setPdfData(null);

    window.electron
      .readFile(book.filepath)
      .then((data) => {
        if (cancelled) return;
        let arr: Uint8Array;
        if (data instanceof ArrayBuffer) {
          arr = new Uint8Array(data);
        } else if (ArrayBuffer.isView(data)) {
          arr = new Uint8Array((data as any).buffer, (data as any).byteOffset, (data as any).byteLength);
        } else {
          const values = Object.values(data as any) as number[];
          arr = new Uint8Array(values);
        }
        setPdfData({ data: arr });
      })
      .catch((err) => {
        if (!cancelled) {
          console.error("[pdf] readFile failed:", err);
          setLoadError(err instanceof Error ? err.message : String(err));
        }
      });

    return () => { cancelled = true; };
  }, [book.filepath]);

  return (
    <div
      ref={scrollContainerRef}
      className={cn(
        "relative h-screen w-full overflow-y-scroll ",
        !isDualPage && isFullscreen ? "" : "",
        "bg-gray-300"
      )}
    >
      {/** White loading screen */}
      {!hasNavigatedToPage && (
        <div className="w-screen h-screen grid place-items-center bg-white z-100 pointer-events-none">
          <Loader2 size={20} className="animate-spin" />
        </div>
      )}

      {/* Fixed Top Bar -- auto-hides after 2s */}
      <ReaderToolbar
        panelsOpen={tocOpen || thumbOpen}
        leftContent={
          <button
            onClick={() => setTocOpen(true)}
            className={cn(
              "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10 border-none",
              "text-black hover:bg-black/10 hover:text-black"
            )}
            aria-label="Open table of contents"
          >
            <MenuIcon size={20} />
          </button>
        }
      >
        <Link
          to="/"
          className="p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10 text-black hover:text-black flex items-center gap-1"
          onClick={() => {
            try {
              localStorage.setItem("lastReadBookId", book.id.toString());
              window.dispatchEvent(new Event("lastReadBookChanged"));
            } catch {}
          }}
        >
          <ChevronLeft size={18} />
          <span className="text-sm">Library</span>
        </Link>

        <button
          onClick={() => setThumbOpen(true)}
          className={cn(
            "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10 border-none",
            "text-black hover:bg-black/10 hover:text-black"
          )}
          aria-label="Open page thumbnails"
        >
          <LayoutGrid size={20} />
        </button>

        <BookmarkButton
          bookSyncId={bookSyncId}
          location={String(currentPageNumber)}
          label={`Page ${currentPageNumber}`}
          className={cn(
            "hover:bg-black/10 dark:hover:bg-white/10 border-none",
            "text-black hover:bg-black/10 hover:text-black"
          )}
        />
        {!isChatting ? (
          <button
            onClick={handleMicClick}
            className={cn(
              "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10",
              "text-black hover:bg-black/10 hover:text-black"
            )}
            aria-label="Start voice chat"
          >
            <Mic size={20} />
          </button>
        ) : (
          <button
            onClick={handleStopChat}
            className={cn(
              "p-2 rounded-md hover:bg-black/10 dark:hover:bg-white/10",
              "text-black hover:bg-black/10 hover:text-black"
            )}
            aria-label="Stop voice chat"
          >
            <MicOff size={20} />
          </button>
        )}
      </ReaderToolbar>

      {/* Main PDF Viewer Area */}
      <div className="flex items-center justify-center  px-2 py-1">
        {loadError && (
          <div className="p-4 text-center">
            <p className="text-red-500">Failed to load PDF: {loadError}</p>
          </div>
        )}
        {!pdfData && !loadError && (
          <div className="w-full h-screen grid place-items-center">
            <Loader2 size={20} className="animate-spin" />
          </div>
        )}
        {pdfData && (
          <Document
            className="flex items-center justify-center flex-col"
            file={pdfData}
            options={pdfOptions}
            onLoadSuccess={onDocumentLoadSuccess}
            onItemClick={onItemClick}
            error={
              <div className={cn("p-4 text-center", "text-black")}>
                <p className="text-red-500">
                  Error loading PDF. Please try again.
                </p>
              </div>
            }
            loading={
              <div
                className={cn(
                  "w-full h-screen grid place-items-center",
                  "text-black"
                )}
              >
                <Loader2 size={20} className="animate-spin" />
              </div>
            }
            externalLinkTarget="_blank"
            externalLinkRel="noopener noreferrer nofollow"
          >
            <div
              style={{
                height: `${virtualizer.getTotalSize()}px`,
                width: "100%",
                position: "relative",
              }}
            >
              {virtualItems.map((virtualItem) => (
                <div key={"collection-" + virtualItem.key}>
                  <div
                    key={virtualItem.key}
                    data-index={virtualItem.index}
                    ref={(node) => {
                      if (node) {
                        pageRefs.current.set(virtualItem.index, node);
                      } else {
                        pageRefs.current.delete(virtualItem.index);
                      }
                      virtualizer.measureElement(node);
                    }}
                    className="absolute left-0 top-0 flex w-full justify-center"
                    style={{
                      transform: `translateY(${virtualItem.start}px)`,
                    }}
                  >
                    <div
                      className="bg-white shadow-lg relative"
                      data-page-number={virtualItem.index + 1}
                      style={{ width: pageWidth ?? "auto" }}
                    >
                      <PageComponent
                        key={`page-${virtualItem.index + 1}`}
                        thispageNumber={virtualItem.index + 1}
                        pdfWidth={pageWidth}
                        pdfHeight={pdfHeight}
                        isDualPage={isDualPage}
                        bookId={book.id.toString()}
                        onRenderComplete={() => {
                          handlePageRendered(virtualItem.index);
                        }}
                      />
                      <div className="group/page absolute bottom-1 left-0 right-0 text-center py-1">
                        <span className="text-xs text-gray-400">
                          <span>{virtualItem.index + 1}</span>
                          {pageCount > 0 && (
                            <span className="hidden group-hover/page:inline"> of {pageCount}</span>
                          )}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div
                    className=" "
                    data-background-page-number={virtualItem.index + 1}
                    style={{ width: pageWidth ?? "auto" }}
                  ></div>
                </div>
              ))}
              <TextExtractor
                pageWidth={pageWidth}
                pdfHeight={pdfHeight}
                isDualPage={isDualPage}
                bookId={book.id.toString()}
              />
            </div>
          </Document>
        )}

        {AuthDialog}

        {/* AI chat orb */}
        {isChatting && (
          <AIChatOrb
            chatStatus={chatStatus}
            onClick={() => setChatPanelOpen((prev) => !prev)}
          />
        )}

        {/* TTS Controls -- visually hidden while AI chat is active (stays mounted to avoid audio cleanup) */}
        <div style={{ display: isChatting ? "none" : "contents" }}>
          <TTSControls key={book.id.toString()} bookId={book.id.toString()} />
        </div>

        {/* Chat Panel */}
        <ChatPanel
          bookId={book.id}
          bookSyncId={bookSyncId}
          bookTitle={book.title}
          rendition={null}
          open={chatPanelOpen}
          onOpenChange={setChatPanelOpen}
        />
      </div>

      {/* TOC Sidebar (inline ReaderTOC for Electron) */}
      <Sheet open={tocOpen} onOpenChange={setTocOpen}>
        <SheetContent
          side="left"
          className={cn("w-[300px] sm:w-[400px] p-0 bg-white border-gray-200")}
        >
          <SheetHeader
            className={cn(
              "p-4 border-b sticky top-0 z-10 border-gray-200 bg-white"
            )}
          >
            <SheetTitle>Table of Contents</SheetTitle>
          </SheetHeader>
          <div className="flex border-b border-gray-200">
            <button
              onClick={() => setTocActiveTab("contents")}
              className={cn(
                "flex-1 px-4 py-2 text-sm font-medium transition-colors",
                tocActiveTab === "contents"
                  ? "border-b-2 border-blue-500 text-blue-600"
                  : "text-gray-500 hover:text-gray-700"
              )}
            >
              Contents
            </button>
            <button
              onClick={() => setTocActiveTab("bookmarks")}
              className={cn(
                "flex-1 px-4 py-2 text-sm font-medium transition-colors",
                tocActiveTab === "bookmarks"
                  ? "border-b-2 border-red-500 text-red-600"
                  : "text-gray-500 hover:text-gray-700"
              )}
            >
              Bookmarks
            </button>
          </div>
          {tocActiveTab === "contents" ? (
            <div className="overflow-y-auto h-[calc(100vh-73px)]">
              <div
                className={cn(
                  "[&_a]:block [&_a]:py-3 [&_a]:px-4 [&_a]:cursor-pointer",
                  "[&_a]:transition-all [&_a]:duration-200",
                  "[&_a]:border-b [&_a]:font-medium",
                  "[&_a]:text-gray-700 [&_a:hover]:bg-gray-100 [&_a:hover]:text-black [&_a]:border-gray-100 [&_a:hover]:pl-6"
                )}
              >
                {pdfData && (
                  <Document
                    file={pdfData}
                    options={pdfOptions}
                  >
                    <Outline onItemClick={onItemClick} />
                  </Document>
                )}
              </div>
            </div>
          ) : (
            <BookmarksList
              bookSyncId={bookSyncId}
              onNavigate={(location) => {
                const pageNum = parseInt(location, 10);
                if (pageNum > 0) {
                  virtualizer.scrollToIndex(pageNum - 1, { align: "start", behavior: "smooth" });
                  setPageNumber(pageNum);
                  setTocOpen(false);
                }
              }}
            />
          )}
        </SheetContent>
      </Sheet>

      {/* Thumbnail Sidebar */}
      <Sheet open={thumbOpen} onOpenChange={setThumbOpen}>
        <SheetContent
          side="left"
          className={cn(
            "w-[200px] sm:w-[240px] p-0",
            "bg-white border-gray-200"
          )}
        >
          <SheetHeader
            className={cn(
              "p-4 border-b sticky top-0 z-10",
              "border-gray-200 bg-white"
            )}
          >
            <SheetTitle className="text-black">
              Pages
            </SheetTitle>
          </SheetHeader>
          <div className="h-[calc(100vh-73px)]">
            <ThumbnailSidebar
              onClose={() => setThumbOpen(false)}
              onNavigate={onThumbnailNavigate}
            />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}

export default PdfView;
