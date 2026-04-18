// Core React imports and third-party libraries
import React, { PureComponent } from "react";
import { type SwipeEventData } from "react-swipeable";
import { EpubView, type IEpubViewProps } from "./epub_viewer";
import type { IEpubViewStyle } from "./epub_viewer/style";
import {
  ReactReaderStyle as defaultStyles,
  type IReactReaderStyle,
} from "./style";
import { type NavItem } from "epubjs";
import {
  SwipeWrapper,
  NavigationArrows,
} from "./components";
import { ReaderTOC } from "@/components/reader/ReaderTOC";
import type { ParagraphWithCFI } from "@/types";

// Recursive TOC item for the ReaderTOC content
function TocItem({ data, setLocation }: { data: NavItem; setLocation: (href: string) => void }) {
  return (
    <div>
      <button
        onClick={() => setLocation(data.href)}
        className="block w-full text-left py-3 px-4 text-sm text-gray-700 hover:bg-gray-100 hover:pl-6 border-b border-gray-100 cursor-pointer transition-all duration-200"
      >
        {data.label}
      </button>
      {data.subitems && data.subitems.length > 0 && (
        <div style={{ paddingLeft: 16 }}>
          {data.subitems.map((item, i) => (
            <TocItem key={i} data={item} setLocation={setLocation} />
          ))}
        </div>
      )}
    </div>
  );
}

// Search result object containing location and excerpt
type SearchResult = { cfi: string; excerpt: string };

/**
 * Props for ReactReader component
 * Extends EpubViewProps with additional UI and interaction features
 */
export type IReactReaderProps = IEpubViewProps & {
  title?: string; // Title displayed at the top of the reader
  showToc?: boolean; // Whether to show table of contents sidebar
  readerStyles?: IReactReaderStyle; // Custom styles for reader UI elements
  epubViewStyles?: IEpubViewStyle; // Custom styles for book rendering area
  swipeable?: boolean; // Enable touch swipe gestures for navigation
  isRTL?: boolean; // Right-to-left reading mode (for languages like Arabic)
  pageTurnOnScroll?: boolean; // Allow mouse wheel scrolling to turn pages
  searchQuery?: string; // Text to search for in the book
  contextLength?: number; // Number of characters to show around search results
  onSearchResults?: (results: SearchResult[]) => void; // Callback with search results
  onPageTextExtracted?: (data: { text: string }) => void; // Callback when page text is extracted
  onPageParagraphsExtracted?: (data: {
    paragraphs: ParagraphWithCFI[];
  }) => void; // Callback when page paragraphs are extracted
  onNextPageParagraphs?: (data: { paragraphs: ParagraphWithCFI[] }) => void;
  onPreviousPageParagraphs?: (data: { paragraphs: ParagraphWithCFI[] }) => void;
  bookSyncId?: string; // Book sync ID for bookmarks in TOC
  tocExpanded?: boolean; // Controlled TOC expanded state
  onTocExpandedChange?: (expanded: boolean) => void; // Callback when TOC is toggled
  hidePrev?: boolean; // Hide the previous-page arrow (e.g. on cover page)
};

// Component state for ReactReader
type IReactReaderState = {
  isLoaded: boolean; // Whether the book has loaded
  expandedToc: boolean; // Whether TOC sidebar is expanded
  toc: NavItem[]; // Parsed table of contents
};

/**
 * ReactReader Component
 * Full-featured EPUB reader with UI controls
 * Provides:
 * - Table of contents sidebar
 * - Navigation controls (arrows, swipe, keyboard, scroll)
 * - Search functionality
 * - Right-to-left (RTL) language support (for languages such as Arabic or Hebrew)
 * - Customizable styling
 */
export class ReactReader extends PureComponent<
  IReactReaderProps,
  IReactReaderState
> {
  state: Readonly<IReactReaderState> = {
    isLoaded: false,
    expandedToc: false,
    toc: [],
  };

  // Reference to the EpubView component for accessing its methods
  readerRef = React.createRef<EpubView>();

  constructor(props: IReactReaderProps) {
    super(props);
  }

  /**
   * Toggle table of contents visibility
   * Opens/closes the TOC sidebar
   */
  toggleToc = () => {
    const { onTocExpandedChange } = this.props;
    if (onTocExpandedChange !== undefined) {
      onTocExpandedChange(!this.getExpandedToc());
    } else {
      this.setState({ expandedToc: !this.state.expandedToc });
    }
  };

  /** Get effective expanded state — controlled prop takes precedence */
  getExpandedToc = () => {
    return this.props.tocExpanded ?? this.state.expandedToc;
  };

  /**
   * Navigate to next page
   * Delegates to the EpubView component's nextPage method
   */
  next = () => {
    const node = this.readerRef.current;
    if (node && node.nextPage) {
      node.nextPage();
    }
  };

  /**
   * Navigate to previous page
   * Delegates to the EpubView component's prevPage method
   */
  prev = () => {
    const node = this.readerRef.current;
    if (node && node.prevPage) {
      node.prevPage();
    }
  };

  /**
   * Handle TOC changes
   * Called when TOC is loaded from the EPUB file
   * Updates state and notifies parent component
   */
  onTocChange = (toc: NavItem[]) => {
    const { tocChanged } = this.props;
    this.setState(
      {
        toc: toc,
      },
      () => tocChanged && tocChanged(toc)
    );
  };

  /**
   * Navigate to a specific location in the book
   * Called when user clicks on a TOC item
   * Closes the TOC and notifies parent component
   */
  setLocation = (loc: string) => {
    const { locationChanged } = this.props;
    // Actually navigate to the location in the book
    const node = this.readerRef.current;
    if (node && node.rendition) {
      void node.rendition.display(loc);
    }
    this.setState(
      {
        expandedToc: false,
      },
      () => locationChanged && locationChanged(loc)
    );
  };

  /**
   * Handle mouse wheel events for page turning
   * Scrolling down -> next page
   * Scrolling up -> previous page
   * Prevents default scrolling behavior
   */
  handleWheel = (event: WheelEvent) => {
    event.preventDefault();

    const node = this.readerRef.current;
    if (!node) return;

    if (event.deltaY > 0) {
      node.nextPage?.();
    } else if (event.deltaY < 0) {
      node.prevPage?.();
    }
  };

  /**
   * Attach wheel event listener to the EPUB iframe
   * The book content is rendered in an iframe, so we need to attach
   * the listener to the iframe's document, not the parent document
   * Uses epub.js hooks to register listener when content loads
   */
  attachWheelListener = () => {
    if (!this.readerRef.current) return;

    const rendition = this.readerRef.current.rendition;

    if (rendition) {
      // Hook into content loading to access iframe document
      rendition.hooks.content.register((contents: { window: { document } }) => {
        const iframeDoc = contents.window.document;

        // Remove any existing listener before adding a new one (prevents duplicates)
        iframeDoc.removeEventListener("wheel", this.handleWheel);
        iframeDoc.addEventListener("wheel", this.handleWheel, {
          passive: false, // Required to call preventDefault()
        });
      });
    }
  };

  /**
   * Search for text throughout the entire book
   * This is a complex function that:
   * 1. Loads each chapter/section of the book
   * 2. Extracts all text nodes from the HTML
   * 3. Searches for the query string (case-insensitive)
   * 4. Creates CFI (Canonical Fragment Identifier) for each match
   * 5. Extracts context around each match
   * 6. Returns array of results with location and excerpt
   *
   * @param query - The text to search for (if empty/null, clears results)
   */
  searchInBook = async (query?: string) => {
    if (!this.readerRef.current) return;
    const rendition = this.readerRef.current?.rendition;
    const book = rendition?.book;
    if (!book) return;

    // Clear results if no query provided
    if (!query) {
      this.props.onSearchResults?.([]);
      return;
    }

    const results: SearchResult[] = [];
    const promises: Promise<void>[] = [];

    // Search through each spine item (chapter/section) in parallel
    book.spine.each((item) => {
      if (query == "" || query == null) results;
      const promise = (async () => {
        try {
          // Load the chapter content
          await item.load(
            book.load.bind(book) as (url: string) => Promise<unknown>
          );
          const doc = item.document;
          const textNodes: Node[] = [];
          if (!doc) return;

          // Walk through DOM to collect all text nodes
          const treeWalker = doc.createTreeWalker(doc, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = treeWalker.nextNode())) {
            textNodes.push(node);
          }

          // Combine all text and search in it (case-insensitive)
          const fullText = textNodes
            .map((n) => n.textContent)
            .join("")
            .toLowerCase();
          const searchQuery = query.toLowerCase();
          let pos = fullText.indexOf(searchQuery);

          // Find all occurrences in this chapter
          while (pos !== -1) {
            // Map the position in combined text back to specific text node
            let nodeIndex = 0;
            let foundOffset = pos;

            // Find which text node contains this match
            while (nodeIndex < textNodes.length) {
              const nodeText = textNodes[nodeIndex].textContent || "";
              if (foundOffset < nodeText.length) break;
              foundOffset -= nodeText.length;
              nodeIndex++;
            }

            if (nodeIndex < textNodes.length) {
              // Create a DOM range for the match
              const range = doc.createRange();
              try {
                range.setStart(textNodes[nodeIndex], foundOffset);
                range.setEnd(
                  textNodes[nodeIndex],
                  foundOffset + searchQuery.length
                );

                // Convert range to CFI (location identifier)
                const cfi = item.cfiFromRange(range);

                // Extract surrounding text for context (default 15 chars before/after)
                const excerpt = `${fullText.substring(
                  Math.max(0, pos - (this.props.contextLength || 15)),
                  pos + searchQuery.length + (this.props.contextLength || 15)
                )}`;

                results.push({ cfi, excerpt });
              } catch (e) {
                console.warn("Skipping invalid range:", e);
              }
            }

            // Find next occurrence
            pos = fullText.indexOf(searchQuery, pos + 1);
          }

          // Unload chapter to free memory
          item.unload();
        } catch (error) {
          console.error("Error searching chapter:", error);
        }
      })();
      promises.push(promise);
    });

    // Wait for all chapters to be searched
    await Promise.all(promises);

    // Only report results if query hasn't changed (prevents race conditions)
    if (query == this.props.searchQuery) {
      this.props.onSearchResults?.(results); // Return array of {cfi, excerpt} objects
    }
  };

  /**
   * Component lifecycle: React to prop changes
   * Handles updates to search query and scroll-to-turn setting
   */
  componentDidUpdate(prevProps: IReactReaderProps) {
    // Trigger new search when search query changes
    if (prevProps.searchQuery !== this.props.searchQuery) {
      void this.searchInBook(this.props.searchQuery);
    }

    // Enable wheel listener for scroll-based page turning
    if (this.props.pageTurnOnScroll === true) {
      this.attachWheelListener();
    }
  }

  /**
   * Main render method
   * Constructs the complete reader UI with:
   * - Title bar
   * - TOC toggle button
   * - Swipe wrapper for touch navigation
   * - Book viewer (EpubView)
   * - Navigation arrows (left/right)
   * - TOC sidebar
   *
   * RTL support: Swaps navigation directions for right-to-left languages
   */
  render() {
    const {
      title,
      showToc = true,
      loadingView,
      errorView,
      readerStyles = defaultStyles,
      locationChanged,
      swipeable,
      epubViewStyles,
      isRTL = false,
      bookSyncId,
      hidePrev = false,
      ...props // Remaining props passed through to EpubView
    } = this.props;
    const { toc } = this.state;
    const expandedToc = this.getExpandedToc();
    return (
      <div style={readerStyles.container}>
        {/* Main reader area */}
        <div style={readerStyles.readerArea}>
          {/* Title bar at top */}
          <div style={readerStyles.titleArea}>{title}</div>

          {/* Swipe gesture wrapper for touch navigation */}
          <SwipeWrapper
            swipeProps={{
              onSwiped: (eventData: SwipeEventData) => {
                const { dir } = eventData;
                if (dir === "Left") {
                  isRTL ? this.prev() : this.next();
                }
                if (dir === "Right") {
                  isRTL ? this.next() : this.prev();
                }
              },
              onTouchStartOrOnMouseDown: ({ event }) => event.preventDefault(),
              touchEventOptions: { passive: false },
              preventScrollOnSwipe: true,
              trackMouse: true,
            }}
            onSwipeLeft={() => (isRTL ? this.prev() : this.next())}
            onSwipeRight={() => (isRTL ? this.next() : this.prev())}
          >
            <div style={readerStyles.reader}>
              <EpubView
                ref={this.readerRef}
                loadingView={
                  loadingView === undefined ? (
                    <div style={readerStyles.loadingView}>Loading…</div>
                  ) : (
                    loadingView
                  )
                }
                errorView={
                  errorView === undefined ? (
                    <div style={readerStyles.errorView}>Error loading book</div>
                  ) : (
                    errorView
                  )
                }
                epubViewStyles={epubViewStyles}
                {...props}
                tocChanged={this.onTocChange}
                locationChanged={locationChanged}
                onPageTextExtracted={this.props.onPageTextExtracted}
                onPageParagraphsExtracted={this.props.onPageParagraphsExtracted}
                onNextPageParagraphs={this.props.onNextPageParagraphs}
                onPreviousPageParagraphs={this.props.onPreviousPageParagraphs}
              />
              {swipeable && <div style={readerStyles.swipeWrapper} />}
            </div>
          </SwipeWrapper>

          {/* Navigation arrow buttons (RTL-aware) */}
          <NavigationArrows
            onPrev={isRTL ? this.next : this.prev}
            onNext={isRTL ? this.prev : this.next}
            readerStyles={readerStyles}
            hidePrev={hidePrev}
          />
        </div>

        {/* Unified TOC sidebar using shared ReaderTOC */}
        {showToc && toc && (
          <ReaderTOC
            open={expandedToc}
            onOpenChange={(open) => {
              if (!open && expandedToc) this.toggleToc();
              if (open && !expandedToc) this.toggleToc();
            }}
            bookSyncId={bookSyncId ?? ""}
            onBookmarkNavigate={(loc) => this.setLocation(loc)}
            tocContent={
              <div className="overflow-y-auto">
                {toc.map((item, i) => (
                  <TocItem
                    key={i}
                    data={item}
                    setLocation={(href: string) => this.setLocation(href)}
                  />
                ))}
              </div>
            }
          />
        )}
      </div>
    );
  }
}
