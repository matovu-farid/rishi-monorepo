import React, { useEffect, useState, useMemo, useRef } from "react";
import { IconButton } from "@components/ui/IconButton";
import { ThemeType } from "@/themes/common";
import { Loader2, Menu as MenuIcon, LayoutGrid } from "lucide-react";
import { Document, Outline, pdfjs } from "react-pdf";
import type { DocumentInitParameters } from "pdfjs-dist/types/src/display/api";
import { eventBus, EventBusEvent, PlayingState } from "@/utils/bus";
import { nextPage, previousPage } from "../utils/pageControls";

import { cn } from "@components/lib/utils";

// Import required CSS for text and annotation layers
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";

import { usePdfStore, BookNavigationState } from "@/stores/pdfStore";
import { ThumbnailSidebar } from "./thumbnail-sidebar";
import TTSControls from "@/components/TTSControls";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "../../components/ui/sheet";
import { useUpdateCoverIMage } from "../hooks/useUpdateCoverIMage";
import { useScrolling } from "../hooks/useScrolling";
import { usePdfNavigation } from "../hooks/usePdfNavigation";
import { PageComponent } from "./pdf-page";
import { useSetupMenu } from "../hooks/useSetupMenu";
import { useMutation } from "@tanstack/react-query";
import { toast } from "react-toastify";
import { queryClient } from "@components/providers";
import { useCurrentPageNumber } from "../hooks/useCurrentPageNumber";
import { PDFDocumentProxy } from "pdfjs-dist";
import { useVirualization } from "../hooks/useVirualization";
import { TextExtractor } from "./text-extractor.tsx";
import { updateBookLocation, Book } from "@/generated";
import { BackButton } from "@components/BackButton.tsx";
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { ReaderToolbar } from "@/components/reader/ReaderToolbar";
import { ReaderTOC } from "@/components/reader/ReaderTOC";

// Configure PDF.js worker
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  "pdfjs-dist/build/pdf.worker.min.mjs",
  import.meta.url
).toString();

export function PdfView({
  book,
  filepath,
}: {
  filepath: String;
  book: Book;
}): React.JSX.Element {
  const [theme] = useState<ThemeType>(ThemeType.White);
  const [tocOpen, setTocOpen] = useState(false);
  const [bookSyncId, setBookSyncId] = useState<string>("");
  const thumbOpen = usePdfStore((s) => s.thumbnailSidebarOpen);
  const setThumbOpen = usePdfStore((s) => s.setThumbnailSidebarOpen);
  const setPdfDocProxy = usePdfStore((s) => s.setPdfDocumentProxy);
  const setBookNavState = usePdfStore((s) => s.setBookNavigationState);

  const setPageNumber = usePdfStore((s) => s.setPageNumber);
  const currentPageNumber = usePdfStore((s) => s.pageNumber);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  useScrolling(scrollContainerRef);

  useUpdateCoverIMage(book);
  useSetupMenu();
  // Ref for the scrollable container

  const resetParaphState = usePdfStore((s) => s.resetParagraphState);

  useEffect(() => {
    return () => {
      resetParaphState();
      setThumbOpen(false);
      setPdfDocProxy(null);
    };
  }, []);

  // Scoped event bus subscriptions for PDF page navigation and highlighting.
  // These must be inside the component lifecycle so they are cleaned up when
  // navigating away from the PDF reader — otherwise they leak across formats.
  useEffect(() => {
    const handleNextEmptied = () => {
      nextPage();
    };
    const handlePrevEmptied = () => {
      previousPage();
    };
    const handlePlayingAudio = (paragraph: { index: string }) => {
      usePdfStore.getState().setIsHighlighting(true);
      usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index);
    };
    const handlePlayingStateChanged = (state: PlayingState) => {
      usePdfStore.getState().setIsHighlighting(state === PlayingState.Playing);
    };

    eventBus.on(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmptied);
    eventBus.on(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmptied);
    eventBus.on(EventBusEvent.PLAYING_AUDIO, handlePlayingAudio);
    eventBus.on(EventBusEvent.PLAYING_STATE_CHANGED, handlePlayingStateChanged);

    return () => {
      eventBus.off(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, handleNextEmptied);
      eventBus.off(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, handlePrevEmptied);
      eventBus.off(EventBusEvent.PLAYING_AUDIO, handlePlayingAudio);
      eventBus.off(EventBusEvent.PLAYING_STATE_CHANGED, handlePlayingStateChanged);
    };
  }, []);

  useEffect(() => {
    void import("@/modules/kysley").then(({ db }) => {
      void db.selectFrom("books")
        .select(["sync_id"])
        .where("id", "=", book.id)
        .executeTakeFirst()
        .then((row) => {
          if (row?.sync_id) setBookSyncId(row.sync_id);
        });
    });
  }, [book.id]);

  // Configure PDF.js options with CDN fallback for better font and image support
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

  // Mount the paragraph atoms so they're available for the player control

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

  function getTextColor() {
    switch (theme) {
      case ThemeType.White:
        return "text-black hover:bg-black/10 hover:text-black";
      case ThemeType.Dark:
        return "text-white hover:bg-white/10 hover:text-white";
      default:
        return "text-black hover:bg-black/10 hover:text-black";
    }
  }

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

  // useCurrentPageNumberNavigation(scrollContainerRef, book.id, virtualizer);
  function onItemClick({ pageNumber: itemPageNumber }: { pageNumber: number }) {
    // Determine direction based on page number comparison
    virtualizer.scrollToIndex(itemPageNumber - 1, {
      align: "start",
      behavior: "smooth",
    });
    setPageNumber(itemPageNumber);
    setTocOpen(false);
    // Update book location when navigating via TOC
    updateBookLocationMutation.mutate({
      bookId: book.id.toString(),
      location: itemPageNumber.toString(),
    });
  }

  function onThumbnailNavigate(pageNumber: number) {
    // Reset navigation state to Idle so setPageNumber is not a no-op
    // (setPageNumberAtom skips if BookNavigationState is Navigating)
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

      {/* Fixed Top Bar — auto-hides after 2s */}
      <ReaderToolbar
        panelsOpen={tocOpen || thumbOpen}
        leftContent={
          <IconButton
            color="inherit"
            onClick={() => setTocOpen(true)}
            className={cn(
              "hover:bg-black/10 dark:hover:bg-white/10 border-none",
              getTextColor()
            )}
            aria-label="Open table of contents"
          >
            <MenuIcon size={20} />
          </IconButton>
        }
      >
        <BackButton />

        <IconButton
          color="inherit"
          onClick={() => setThumbOpen(true)}
          className={cn(
            "hover:bg-black/10 dark:hover:bg-white/10 border-none",
            getTextColor()
          )}
          aria-label="Open page thumbnails"
        >
          <LayoutGrid size={20} />
        </IconButton>

        <BookmarkButton
          bookSyncId={bookSyncId}
          location={String(currentPageNumber)}
          label={`Page ${currentPageNumber}`}
          className={cn(
            "hover:bg-black/10 dark:hover:bg-white/10 border-none",
            getTextColor()
          )}
        />
      </ReaderToolbar>

      {/* Main PDF Viewer Area */}
      <div className="flex items-center justify-center  px-2 py-1">
        <Document
          className="flex items-center justify-center flex-col"
          file={filepath.toString()}
          options={pdfOptions}
          onLoadSuccess={onDocumentLoadSuccess}
          onItemClick={onItemClick}
          error={
            <div className={cn("p-4 text-center", getTextColor())}>
              <p className="text-red-500">
                Error loading PDF. Please try again.
              </p>
            </div>
          }
          loading={
            <div
              className={cn(
                "w-full h-screen grid place-items-center",
                getTextColor()
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
                  }}
                  className="absolute left-0 top-0 flex w-full justify-center"
                  style={{
                    transform: `translateY(${virtualItem.start}px)`,
                  }}
                >
                  <div
                    className="bg-white shadow-lg overflow-hidden relative"
                    data-page-number={virtualItem.index + 1}
                    style={{ width: pageWidth ?? "auto", height: virtualItem.size }}
                  >
                    <PageComponent
                      key={`page-${virtualItem.index + 1}`}
                      thispageNumber={virtualItem.index + 1}
                      pdfWidth={pageWidth}
                      pdfHeight={pdfHeight}
                      isDualPage={isDualPage}
                      bookId={book.id.toString()}
                      onRenderComplete={() => {
                        // setHasNavigatedToPage(true);
                        // handlePageRendered(virtualItem.index)
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
        {/* TTS Controls - Draggable */}
        {<TTSControls key={book.id.toString()} bookId={book.id.toString()} />}
      </div>
      {/* TOC Sidebar */}
      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        bookSyncId={bookSyncId}
        onBookmarkNavigate={(location) => {
          const pageNum = parseInt(location, 10);
          if (pageNum > 0) {
            virtualizer.scrollToIndex(pageNum - 1, { align: "start", behavior: "smooth" });
            setPageNumber(pageNum);
            setTocOpen(false);
          }
        }}
        tocContent={
          <div
            className={cn(
              "[&_a]:block [&_a]:py-3 [&_a]:px-4 [&_a]:cursor-pointer",
              "[&_a]:transition-all [&_a]:duration-200",
              "[&_a]:border-b [&_a]:font-medium",
              "[&_a]:text-gray-700 [&_a:hover]:bg-gray-100 [&_a:hover]:text-black [&_a]:border-gray-100 [&_a:hover]:pl-6"
            )}
          >
            <Document
              file={filepath.toString()}
              options={pdfOptions}
            >
              <Outline onItemClick={onItemClick} />
            </Document>
          </div>
        }
      />
      {/* Thumbnail Sidebar */}
      <Sheet open={thumbOpen} onOpenChange={setThumbOpen}>
        <SheetContent
          side="left"
          className={cn(
            "w-[200px] sm:w-[240px] p-0",
            theme === ThemeType.Dark
              ? "bg-gray-900 border-gray-700"
              : "bg-white border-gray-200"
          )}
        >
          <SheetHeader
            className={cn(
              "p-4 border-b sticky top-0 z-10",
              theme === ThemeType.Dark
                ? "border-gray-700 bg-gray-900"
                : "border-gray-200 bg-white"
            )}
          >
            <SheetTitle className={getTextColor()}>
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
