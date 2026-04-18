import Loader from "@components/Loader";
import { ReactReader } from "@components/react-reader";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "react-toastify";

import React, { useCallback, useEffect, useRef, useState } from "react";
import { Menu } from "@components/ui/Menu";
import { Radio, RadioGroup } from "@components/ui/Radio";
import { ThemeType } from "@/themes/common";
import { themes } from "@/themes/themes";
import createIReactReaderTheme from "@/themes/readerThemes";
import { Palette, Highlighter, MessageSquare, MoreVertical, Menu as MenuIcon } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import {
  Popover,
  PopoverTrigger,
  PopoverContent,
} from "@components/components/ui/popover";
import TTSControls from "@components/TTSControls";
import { Rendition } from "epubjs/types";
import { convertFileSrc } from "@tauri-apps/api/core";
import { motion, AnimatePresence } from "framer-motion";
import { useEpubStore } from "@/stores/epubStore";
import {
  eventBus,
  EventBusEvent,
  PlayingState,
} from "@/utils/bus";
import { highlightRange, removeHighlight, getCurrentViewParagraphs } from "@/epubwrapper";
import { Book } from "@/generated";
import { updateBookLocation } from "@/generated";
import { BackButton } from "./BackButton";
import { saveHighlight, getHighlightsForBook } from "@/modules/highlight-storage";
import { triggerSyncOnWrite } from "@/modules/sync-triggers";
import { db } from "@/modules/kysley";
import { getHighlightHex } from "@/types/highlight";
import type { HighlightColor } from "@/types/highlight";
import type { Contents } from "epubjs";
import { SelectionPopover } from "@/components/highlights/SelectionPopover";
import { HighlightsPanel } from "@/components/highlights/HighlightsPanel";
import { ReaderSettings } from "@/components/reader/ReaderSettings";
import { ReaderToolbar } from "@/components/reader/ReaderToolbar";
import { ChatPanel } from "@/components/chat/ChatPanel";
import { useRequireAuth } from "@/hooks/useRequireAuth";
import { BookmarkButton } from "@/components/bookmarks/BookmarkButton";
import { BookmarksList } from "@/components/bookmarks/BookmarksList";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@components/components/ui/sheet";
import { ScrollArea } from "@components/components/ui/scroll-area";
import { usePageTracker } from "@/modules/epub-page-tracker";
import { dumpError } from "@/utils/errorDump";

function cn(...classes: string[]) {
  return classes.filter(Boolean).join(" ");
}

function updateTheme(rendition: Rendition, theme: ThemeType) {
  const reditionThemes = rendition.themes;
  reditionThemes.override("color", themes[theme].color);
  reditionThemes.override("background", themes[theme].background);
  reditionThemes.override("font-size", "1.2em");
}

export function EpubView({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme);
  const setTheme = useEpubStore((s) => s.setTheme);
  const [menuOpen, setMenuOpen] = useState(false);
  const [currentLocation, setCurrentLocation] = useState<string>(
    book.location || "0"
  );
  const [direction, setDirection] = useState<"left" | "right">("right");

  // Sync with book.location when it changes from a refetch (e.g., returning from library).
  // Only sync before the rendition has settled to avoid overriding user navigation.
  const bookLocationRef = useRef(book.location);
  useEffect(() => {
    if (book.location && book.location !== bookLocationRef.current && !settledRef.current) {
      bookLocationRef.current = book.location;
      setCurrentLocation(book.location);
      dumpError({
        source: "epub:syncLocation",
        location: "refetch",
        error: JSON.stringify({ newLocation: book.location }),
      });
    }
  }, [book.location]);
  const navigationDirectionRef = useRef<"left" | "right">("right");
  const [animationKey, setAnimationKey] = useState(0);
  const animationTriggerRef = useRef(0);
  const rendition = useEpubStore((s) => s.rendition);
  const setRendition = useEpubStore((s) => s.setRendition);
  const bookSyncIdRef = useRef<string | null>(null);
  const [bookSyncId, setBookSyncId] = useState<string>("");
  const [bookmarksPanelOpen, setBookmarksPanelOpen] = useState(false);
  const [tocOpen, setTocOpen] = useState(false);
  const pageReady = usePageTracker((s) => s.ready);
  const pageCurrent = usePageTracker((s) => s.current);
  const pageTotal = usePageTracker((s) => s.total);
  const [isFirstPage, setIsFirstPage] = useState(false);
  const [isFrontMatter, setIsFrontMatter] = useState(false);
  // Don't save location to DB until rendition has settled at the saved position.
  // Without this, the transient initial position overwrites the correct saved CFI.
  const settledRef = useRef(false);
  const [selectionInfo, setSelectionInfo] = useState<{
    cfiRange: string; text: string; position: { x: number; y: number };
  } | null>(null);
  const [highlightsPanelOpen, setHighlightsPanelOpen] = useState(false);
  const [chatPanelOpen, setChatPanelOpen] = useState(false);
  const { requireAuth, AuthDialog } = useRequireAuth();

  // Keep toolbar visible when any panel is open
  const panelOpen = menuOpen || highlightsPanelOpen || chatPanelOpen || bookmarksPanelOpen || tocOpen || !!selectionInfo;

  // Look up the book's sync_id for highlight storage and bookmark functionality
  useEffect(() => {
    void db.selectFrom('books')
      .select(['sync_id'])
      .where('id', '=', book.id)
      .executeTakeFirst()
      .then((row) => {
        bookSyncIdRef.current = row?.sync_id ?? null;
        if (row?.sync_id) setBookSyncId(row.sync_id);
      });
  }, [book.id]);

  // Load persisted highlights when rendition is ready
  useEffect(() => {
    if (!rendition || !bookSyncIdRef.current) return;
    const syncId = bookSyncIdRef.current;
    void getHighlightsForBook(syncId).then((highlights) => {
      for (const hl of highlights) {
        const hex = getHighlightHex(hl.color as HighlightColor);
        void highlightRange(rendition, hl.cfi_range, {}, () => {}, 'epubjs-hl', {
          fill: hex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply',
        });
      }
    });
  }, [rendition]);

  // Handle user text selection -- show color picker popover instead of auto-highlight
  const handleTextSelected = useCallback((cfiRange: string, contents: Contents) => {
    const syncId = bookSyncIdRef.current;
    if (!syncId || !rendition) return;

    const selection = contents.window.getSelection();
    const selectedText = selection?.toString() ?? '';
    if (!selectedText.trim()) return;

    // Get selection position for popover placement
    const range = selection?.getRangeAt(0);
    const rect = range?.getBoundingClientRect();
    const iframeEl = contents.document.defaultView?.frameElement;
    const iframeRect = iframeEl?.getBoundingClientRect();
    const x = (rect?.left ?? 0) + (iframeRect?.left ?? 0);
    const y = (rect?.top ?? 0) + (iframeRect?.top ?? 0) - 50;

    setSelectionInfo({ cfiRange, text: selectedText, position: { x, y } });
  }, [rendition]);

  // Handle color selection from the popover
  const handleHighlightColor = useCallback((color: HighlightColor) => {
    if (!selectionInfo || !rendition || !bookSyncIdRef.current) return;
    const hex = getHighlightHex(color);
    void highlightRange(rendition, selectionInfo.cfiRange, {}, () => {}, 'epubjs-hl', {
      fill: hex, 'fill-opacity': '0.3', 'mix-blend-mode': 'multiply',
    });
    void saveHighlight({
      bookSyncId: bookSyncIdRef.current,
      cfiRange: selectionInfo.cfiRange,
      text: selectionInfo.text,
      color,
    }).then(() => triggerSyncOnWrite())
      .catch((err) => console.warn('[highlight] save failed:', err));
    setSelectionInfo(null);
  }, [selectionInfo, rendition]);

  async function clearAllHighlights() {
    if (!rendition) return;
    const paragraphs = getCurrentViewParagraphs(rendition);
    return Promise.all(
      paragraphs.map((paragraph) => removeHighlight(rendition, paragraph.cfiRange))
    );
  }
  const setBookId = useEpubStore((s) => s.setBookId);
  useEffect(() => {
    setBookId(book.id.toString());
    usePageTracker.getState().initBook(book.id.toString());
  }, [book.id]);

  useEffect(() => {
    if (!rendition) return;

    const onNextPageEmptied = async () => {
      await clearAllHighlights();
      await rendition.next();
      eventBus.publish(EventBusEvent.PAGE_CHANGED);
    };
    const onPrevPageEmptied = async () => {
      await clearAllHighlights();
      await rendition.prev();
      eventBus.publish(EventBusEvent.PAGE_CHANGED);
    };
    const onPlayingAudio = async (paragraph: { index: string }) => {
      await highlightRange(rendition, paragraph.index);
    };
    const onAudioEnded = async (paragraph: { index: string }) => {
      await removeHighlight(rendition, paragraph.index);
    };
    const onMovedToNext = async ({ from: paragraph }: { from: { index: string } }) => {
      await removeHighlight(rendition, paragraph.index);
    };
    const onMovedToPrev = async ({ from: paragraph }: { from: { index: string } }) => {
      await removeHighlight(rendition, paragraph.index);
    };
    const onPlayingStateChanged = async (playingState: PlayingState) => {
      if (playingState !== PlayingState.Playing) {
        await clearAllHighlights();
      }
    };

    eventBus.subscribe(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, onNextPageEmptied);
    eventBus.subscribe(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, onPrevPageEmptied);
    eventBus.subscribe(EventBusEvent.PLAYING_AUDIO, onPlayingAudio);
    eventBus.subscribe(EventBusEvent.AUDIO_ENDED, onAudioEnded);
    eventBus.subscribe(EventBusEvent.MOVED_TO_NEXT_PARAGRAPH, onMovedToNext);
    eventBus.subscribe(EventBusEvent.MOVED_TO_PREV_PARAGRAPH, onMovedToPrev);
    eventBus.subscribe(EventBusEvent.PLAYING_STATE_CHANGED, onPlayingStateChanged);

    return () => {
      eventBus.off(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, onNextPageEmptied);
      eventBus.off(EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED, onPrevPageEmptied);
      eventBus.off(EventBusEvent.PLAYING_AUDIO, onPlayingAudio);
      eventBus.off(EventBusEvent.AUDIO_ENDED, onAudioEnded);
      eventBus.off(EventBusEvent.MOVED_TO_NEXT_PARAGRAPH, onMovedToNext);
      eventBus.off(EventBusEvent.MOVED_TO_PREV_PARAGRAPH, onMovedToPrev);
      eventBus.off(EventBusEvent.PLAYING_STATE_CHANGED, onPlayingStateChanged);
    };
  }, [rendition]);

  useEffect(() => {
    if (rendition) {
      updateTheme(rendition, theme);
    }
  }, [theme]);

  // Track cover page & recalculate avgLocsPerPage on resize/aspect ratio change
  useEffect(() => {
    if (!rendition) return;

    const onRelocated = () => {
      const loc = (rendition as any).location;
      const spineIndex = loc?.start?.index ?? -1;
      setIsFirstPage(spineIndex === 0);
      setIsFrontMatter(spineIndex <= 1); // Hide page number on cover + title page
    };

    // Remeasure avgLocsPerPage when layout changes (resize, orientation)
    const onResized = () => {
      const pt = usePageTracker.getState();
      if (!pt.ready || !pt.locationsReady) return;
      const startCfi = (rendition as any)?.location?.start?.cfi;
      const endCfi = (rendition as any)?.location?.end?.cfi;
      if (startCfi && endCfi) {
        const s = rendition.book.locations.locationFromCfi(startCfi) as unknown as number;
        const e = rendition.book.locations.locationFromCfi(endCfi) as unknown as number;
        if (typeof s === 'number' && typeof e === 'number' && e > s) {
          const rawLocCount = ((rendition.book.locations as any)._locations ?? []).length;
          pt.build(rawLocCount, e - s);
        }
      }
    };

    rendition.on('relocated', onRelocated);
    rendition.on('resized', onResized);
    return () => {
      rendition.off('relocated', onRelocated);
      rendition.off('resized', onResized);
    };
  }, [rendition]);

  const setCurrentEpubLocation = useEpubStore((s) => s.setCurrentEpubLocation);

  const setParagraphRendition = useEpubStore((s) => s.setParagraphRendition);
  // Track navigation direction by intercepting prev/next when rendition is available
  useEffect(() => {
    if (!rendition) return;

    const originalPrev = rendition.prev;
    const originalNext = rendition.next;

    rendition.prev = function () {
      navigationDirectionRef.current = "left";
      return originalPrev.call(this);
    };

    rendition.next = function () {
      navigationDirectionRef.current = "right";
      return originalNext.call(this);
    };

    return () => {
      rendition.prev = originalPrev;
      rendition.next = originalNext;
    };
  }, [rendition]);

  const handleThemeChange = (newTheme: ThemeType) => {
    setTheme(newTheme);
    setMenuOpen(false);
  };

  const queryClient = useQueryClient();
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
    onSuccess(_data, variables) {
      void queryClient.invalidateQueries({ queryKey: ["book", variables.bookId] });
    },
    onError(_error) {
      toast.error("Can not change book page");
    },
  });
  // Update rendition state when ref becomes available

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

  return (
    <div className="relative">
      {/* Unified top toolbar — matches PDF layout */}
      <ReaderToolbar
        panelsOpen={panelOpen}
        leftContent={
          <IconButton
            color="inherit"
            onClick={() => setTocOpen((v) => !v)}
            className="hover:bg-transparent border-none"
          >
            <MenuIcon size={20} className={getTextColor()} />
          </IconButton>
        }
      >
        <BackButton />

        <BookmarkButton
          bookSyncId={bookSyncId}
          location={currentLocation}
          label={undefined}
          className="hover:bg-transparent border-none"
        />

        <ReaderSettings rendition={rendition} />

        <Popover>
          <PopoverTrigger asChild>
            <button
              className={cn("p-2 rounded-md", getTextColor())}
              aria-label="More options"
            >
              <MoreVertical size={20} />
            </button>
          </PopoverTrigger>
          <PopoverContent className="w-48 p-1" align="end">
            <button
              onClick={() => setBookmarksPanelOpen(true)}
              className="flex items-center gap-3 px-3 py-2 text-sm rounded hover:bg-accent w-full text-left"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z" />
                <line x1="9" y1="10" x2="15" y2="10" />
                <line x1="12" y1="7" x2="12" y2="13" />
              </svg>
              Bookmarks
            </button>
            <button
              onClick={() => setHighlightsPanelOpen(true)}
              className="flex items-center gap-3 px-3 py-2 text-sm rounded hover:bg-accent w-full text-left"
            >
              <Highlighter size={16} />
              Highlights
            </button>
            <button
              onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
              className="flex items-center gap-3 px-3 py-2 text-sm rounded hover:bg-accent w-full text-left"
            >
              <MessageSquare size={16} />
              Chat
            </button>
            <button
              onClick={() => setMenuOpen(true)}
              className="flex items-center gap-3 px-3 py-2 text-sm rounded hover:bg-accent w-full text-left"
            >
              <Palette size={16} />
              Theme
            </button>
          </PopoverContent>
        </Popover>
      </ReaderToolbar>

      {/* Theme menu (triggered from more menu) */}
      <Menu
        trigger={<span />}
        open={menuOpen}
        onOpen={() => setMenuOpen(true)}
        onClose={() => setMenuOpen(false)}
        anchorOrigin={{ vertical: "bottom", horizontal: "right" }}
        theme={themes[theme]}
      >
        <div className="p-3">
          <RadioGroup
            value={theme}
            onChange={(value) => handleThemeChange(value as ThemeType)}
            name="theme-selector"
            theme={themes[theme]}
          >
            {(Object.keys(themes) as Array<keyof typeof themes>).map(
              (themeKey) => (
                <Radio
                  key={themeKey}
                  value={themeKey}
                  label={themeKey}
                  theme={themes[theme]}
                />
              )
            )}
          </RadioGroup>
        </div>
      </Menu>
      <div
        style={{ height: "100vh", position: "relative", overflow: "hidden" }}
      >
        <ReactReader
          key={`reader-${book.id}`}
          showToc={true}
          bookSyncId={bookSyncId}
          tocExpanded={tocOpen}
          onTocExpandedChange={setTocOpen}
          hidePrev={isFirstPage}
          loadingView={
            <div className="w-full h-screen grid items-center">
              <Loader />
            </div>
          }
          url={convertFileSrc(book.filepath)}
          title={book.title}
          location={currentLocation || book.location || 0}
          locationChanged={(epubcfi: string) => {
            // Use tracked navigation direction from intercepted prev/next calls
            setDirection(navigationDirectionRef.current);
            setCurrentLocation(epubcfi);
            animationTriggerRef.current += 1;
            setAnimationKey(animationTriggerRef.current);

            // Dump every locationChanged for debugging
            dumpError({
              source: "epub:locationChanged",
              location: "locationChanged",
              error: JSON.stringify({
                epubcfi,
                settled: settledRef.current,
                bookLocation: book.location,
              }),
            });

            // Only save to DB after rendition has settled at the saved position.
            // Transient positions during initial load must not overwrite the saved CFI.
            if (settledRef.current) {
              updateBookLocationMutation.mutate({
                bookId: book.id.toString(),
                location: epubcfi,
              });
              triggerSyncOnWrite();
            }

            setCurrentEpubLocation(epubcfi);

            // Track page from actual CFI position (only after locations are generated)
            const pt = usePageTracker.getState();
            if (pt.ready && pt.locationsReady) {
              pt.goToCfi(
                epubcfi,
                (c: string) => rendition!.book.locations.locationFromCfi(c) as unknown as number,
              );
            }
          }}
          swipeable={true}
          readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
          handleTextSelected={handleTextSelected}
          getRendition={(_rendition) => {
            updateTheme(_rendition, theme);

            // Make the cover (first spine section) appear on the right side
            // of the first two-page spread by injecting a blank column spacer.
            _rendition.hooks.content.register((contents: any) => {
              if (contents.sectionIndex === 0) {
                const doc = contents.document as Document;
                const spacer = doc.createElement('div');
                spacer.setAttribute('data-cover-spacer', 'true');
                spacer.style.breakAfter = 'column';
                spacer.style.height = '100%';
                doc.body.insertBefore(spacer, doc.body.firstChild);
              }
            });

            _rendition.once("rendered", () => {
              setRendition(_rendition);
              const pt = usePageTracker.getState();

              const CHARS_PER_PAGE = 1600;
              const locsCacheKey = `epub-locs-v5-${book.id}`;
              // Clean up old cache versions
              localStorage.removeItem(`epub-locations-${book.id}`);
              localStorage.removeItem(`epub-locs-v2-${book.id}`);
              localStorage.removeItem(`epub-pages-v3-${book.id}`);
              localStorage.removeItem(`epub-pages-v4-${book.id}`);
              localStorage.removeItem(`epub-pages-v5-${book.id}`);

              const locFromCfi = (c: string) =>
                _rendition.book.locations.locationFromCfi(c) as unknown as number;

              // Measure how many location markers fit in one visible spread
              const measureLocsPerView = (): number => {
                const startCfi = (_rendition as any)?.location?.start?.cfi;
                const endCfi = (_rendition as any)?.location?.end?.cfi;
                if (startCfi && endCfi) {
                  const s = locFromCfi(startCfi);
                  const e = locFromCfi(endCfi);
                  if (typeof s === 'number' && typeof e === 'number' && e > s) {
                    return e - s;
                  }
                }
                return 2; // sensible default for two-page spread
              };

              // Try restoring locations from localStorage cache (instant)
              const cachedLocs = localStorage.getItem(locsCacheKey);
              if (cachedLocs && pt.ready) {
                // Restore epub.js locations instantly — no generate() needed
                _rendition.book.locations.load(cachedLocs);
                pt.setLocationsReady(true);

                // Wait for epub.js to navigate to the saved location before
                // reading position. "rendered" fires before display() completes,
                // so location.start.cfi is stale until "relocated" fires.
                const seedOnRelocated = () => {
                  _rendition.off('relocated', seedOnRelocated);
                  const cfi = (_rendition as any)?.location?.start?.cfi;
                  if (cfi) {
                    usePageTracker.getState().goToCfi(cfi, locFromCfi);
                  }
                  settledRef.current = true;
                };
                _rendition.on('relocated', seedOnRelocated);
                return;
              }

              // No cache — generate locations (slow, first time only)
              void _rendition.book.locations.generate(CHARS_PER_PAGE).then(() => {
                usePageTracker.getState().setLocationsReady(true);

                // Cache raw locations for instant restore next time
                try { localStorage.setItem(locsCacheKey, _rendition.book.locations.save()); } catch {}

                // Wait for relocated so we can measure locsPerView
                const buildOnce = () => {
                  _rendition.off('relocated', buildOnce);
                  const rawLocCount = ((_rendition.book.locations as any)._locations ?? []).length;
                  const avgLocsPerPage = measureLocsPerView();
                  usePageTracker.getState().build(rawLocCount, avgLocsPerPage);

                  // Seed current page
                  const startCfi = (_rendition as any)?.location?.start?.cfi;
                  if (startCfi) {
                    usePageTracker.getState().goToCfi(startCfi, locFromCfi);
                  }
                  settledRef.current = true;
                };

                // Always wait for relocated — it fires after epub.js navigates
                // to the saved location, ensuring location.start.cfi is correct
                _rendition.on('relocated', buildOnce);
              });
            });
          }}
        />
        <AnimatePresence>
          {animationKey > 0 && (
            <motion.div
              key={animationKey}
              initial={{
                opacity: 0.3,
                x: direction === "right" ? 100 : -100,
              }}
              animate={{
                opacity: 0,
                x: 0,
              }}
              exit={{
                opacity: 0,
              }}
              transition={{
                duration: 0.3,
                ease: [0.4, 0, 0.2, 1],
              }}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                height: "100%",
                pointerEvents: "none",
                backgroundColor: themes[theme].background,
                zIndex: 10,
              }}
            />
          )}
        </AnimatePresence>
      </div>
      <div className="fixed top-0 left-9999 right-9999 bottom-0 -z-30 pointer-events-none opacity-0">
        <div
          style={{ height: "100vh", position: "relative", overflow: "hidden" }}
        >
          <ReactReader
            key={`reader-paragraph-${book.id}`}
            loadingView={
              <div className="w-full h-screen grid items-center">
                <Loader />
              </div>
            }
            url={convertFileSrc(book.filepath)}
            title={book.title}
            location={currentLocation || book.location || 0}
            locationChanged={() => {}}
            swipeable={true}
            readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
            getRendition={(_rendition) => {
              _rendition.once("rendered", () => {
                setParagraphRendition(_rendition);
              });
            }}
          />
        </div>
      </div>

      {/* TTS Controls - Draggable */}
      {<TTSControls bookId={book.id.toString()} />}

      {/* Highlight color picker popover */}
      {selectionInfo && (
        <SelectionPopover
          cfiRange={selectionInfo.cfiRange}
          selectedText={selectionInfo.text}
          position={selectionInfo.position}
          onHighlight={handleHighlightColor}
          onClose={() => setSelectionInfo(null)}
        />
      )}

      {/* Highlights side panel */}
      <HighlightsPanel
        bookSyncId={bookSyncIdRef.current ?? ''}
        rendition={rendition}
        open={highlightsPanelOpen}
        onOpenChange={setHighlightsPanelOpen}
      />

      {/* Bookmarks side panel */}
      <Sheet open={bookmarksPanelOpen} onOpenChange={setBookmarksPanelOpen}>
        <SheetContent side="right" className="w-[400px] flex flex-col">
          <SheetHeader>
            <SheetTitle className="text-lg font-semibold">Bookmarks</SheetTitle>
          </SheetHeader>
          <ScrollArea className="flex-1 px-4">
            <BookmarksList
              bookSyncId={bookSyncId}
              onNavigate={(location) => {
                const rendition = useEpubStore.getState().rendition;
                if (rendition) {
                  void rendition.display(location);
                }
                setBookmarksPanelOpen(false);
              }}
            />
          </ScrollArea>
        </SheetContent>
      </Sheet>

      {AuthDialog}

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={rendition}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />

      {/* Page number indicator — shows "X" normally, "X of Y" on hover; hidden on front matter */}
      {pageReady && !isFrontMatter && (
        <div
          className="group/page"
          style={{
            position: 'fixed',
            bottom: 0,
            left: 0,
            right: 0,
            textAlign: 'center',
            zIndex: 5,
            padding: '8px 0',
          }}
        >
          <span
            style={{
              fontSize: 12,
              color: themes[theme].color,
              opacity: 0.4,
            }}
          >
            <span>{pageCurrent}</span>
            <span className="hidden group-hover/page:inline"> of {pageTotal}</span>
          </span>
        </div>
      )}
    </div>
  );
}
