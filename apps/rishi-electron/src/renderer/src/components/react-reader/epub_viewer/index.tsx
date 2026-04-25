// Core imports for React component and ePub.js library
import React, { Component } from "react";

import type { NavItem, Contents, Rendition, Location, Book } from "epubjs";
import { EpubViewStyle as defaultStyles, type IEpubViewStyle } from "./style";
import type { ParagraphWithCFI } from "../../../types";
import {
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs,
  highlightRange,
  initialize,
  removeHighlight,
} from "../../../modules/epubwrapper";
import { useNavStore } from "../../../stores/navStore";

export { EpubViewStyle } from "./style";

type RenditionOptions = Rendition["settings"];

// Extended rendition options to include popup handling capability
export type RenditionOptionsFix = RenditionOptions & {
  allowPopups: boolean;
};

type BookOptions = Book["settings"];

// Type definition for table of contents items
export type IToc = {
  label: string;
  href: string;
};

/**
 * Props interface for EpubView component
 * This component is the core viewer that handles rendering EPUB books
 */
export type IEpubViewProps = {
  url: string | ArrayBuffer; // The EPUB file source (can be URL or raw data)
  epubInitOptions?: Partial<BookOptions>; // Options for initializing the book
  epubOptions?: Partial<RenditionOptionsFix>; // Options for rendering the book
  epubViewStyles?: IEpubViewStyle; // Custom styling for the viewer
  loadingView?: React.ReactNode; // Custom loading indicator
  errorView?: React.ReactNode; // Custom error display
  location: string | number | null; // Current reading location (CFI or page number)
  locationChanged(value: string): void; // Callback when user navigates to new location
  showToc?: boolean; // Whether to display table of contents
  tocChanged?(value: NavItem[]): void; // Callback when TOC is loaded
  getRendition?(rendition: Rendition): void; // Callback to access rendition instance
  handleKeyPress?(): void; // Custom keyboard event handler
  handleTextSelected?(cfiRange: string, contents: Contents): void; // Callback when text is selected
  onPageTextExtracted?(data: { text: string }): void; // Callback when page text is extracted
  onPageParagraphsExtracted?(data: { paragraphs: ParagraphWithCFI[] }): void; // Callback when page paragraphs are extracted
  onNextPageParagraphs?(data: { paragraphs: ParagraphWithCFI[] }): void; // Callback when next page paragraphs are extracted
  onPreviousPageParagraphs?(data: { paragraphs: ParagraphWithCFI[] }): void; // Callback when previous page paragraphs are extracted
};

// Component state tracking loading status and table of contents
type IEpubViewState = {
  isLoaded: boolean; // Whether the book has finished loading
  isError: boolean; // Whether an error occurred during loading
  toc: NavItem[]; // Parsed table of contents
};

/**
 * EpubView Component
 * Core component responsible for rendering EPUB books using epub.js library
 * Handles book initialization, rendering, navigation, and event management
 */
export class EpubView extends Component<IEpubViewProps, IEpubViewState> {
  state: Readonly<IEpubViewState> = {
    isLoaded: false,
    isError: false,
    toc: [],
  };

  // Reference to the DOM element where the book will be rendered
  viewerRef = React.createRef<HTMLDivElement>();

  // Instance variables for tracking book state
  location?: string | number | null; // Current reading position
  book?: Book; // The epub.js Book instance
  rendition?: Rendition; // The epub.js Rendition instance (handles display)
  prevPage?: () => void; // Function to navigate to previous page
  nextPage?: () => void; // Function to navigate to next page

  constructor(props: IEpubViewProps) {
    super(props);
    this.location = props.location;
    this.book = this.rendition = this.prevPage = this.nextPage = undefined;
  }

  /**
   * Component lifecycle: Setup
   */
  componentDidMount() {
    this.initBook();
    document.addEventListener("keyup", this.handleKeyPress, false);
  }

  /**
   * Initialize the EPUB book
   */
  initBook() {
    const { url, tocChanged, epubInitOptions = {} } = this.props;
    if (this.book) {
      this.book.destroy();
    }
    this.book = initialize(url, epubInitOptions);

    void this.book?.loaded.navigation.then(({ toc }) => {
      this.setState(
        {
          isLoaded: true,
          isError: false,
          toc: toc,
        },
        () => {
          tocChanged && tocChanged(toc);
          this.initReader();
        }
      );
    });
  }

  /**
   * Component lifecycle: Cleanup
   */
  componentWillUnmount() {
    if (this.rendition) {
      try {
        this.rendition.destroy();
      } catch (error) {
        console.warn("Error destroying rendition:", error);
      }
      this.rendition = undefined;
    }

    if (this.book) {
      try {
        this.book.destroy();
      } catch (error) {
        console.warn("Error destroying book:", error);
      }
    }

    this.book = this.prevPage = this.nextPage = undefined;
    document.removeEventListener("keyup", this.handleKeyPress, false);
  }

  /**
   * Performance optimization: Control when component should re-render
   */
  shouldComponentUpdate(nextProps: IEpubViewProps) {
    return (
      !this.state.isLoaded ||
      nextProps.location !== this.props.location ||
      nextProps.url !== this.props.url
    );
  }

  /**
   * Component lifecycle: Handle prop changes
   */
  componentDidUpdate(prevProps: IEpubViewProps) {
    if (
      prevProps.location !== this.props.location &&
      this.location !== this.props.location
    ) {
      void this.rendition?.display(this.props.location + "");
    }
    if (prevProps.url !== this.props.url) {
      this.initBook();
    }
  }

  /**
   * Initialize the EPUB reader (rendition)
   */
  initReader() {
    const { toc } = this.state;
    const { location, epubOptions, getRendition } = this.props;
    if (this.viewerRef.current) {
      const node = this.viewerRef.current;
      if (this.book) {
        const rendition = this.book.renderTo(node, {
          width: "100%",
          height: "100%",
          manager: "continuous",
          ...epubOptions,
        });
        this.rendition = rendition;

        this.prevPage = () => {
          void rendition.prev();
        };
        this.nextPage = () => {
          void rendition.next();
          rendition.emit("nextPage");
        };

        this.registerEvents();

        getRendition && getRendition(rendition);

        if (typeof location === "string" || typeof location === "number") {
          void rendition.display(location + "");
        } else if (toc.length > 0 && toc[0].href) {
          void rendition.display(toc[0].href);
        } else {
          void rendition.display("");
        }
      }
    }
  }

  /**
   * Register event listeners for the rendition
   */
  registerEvents() {
    const { handleKeyPress, handleTextSelected } = this.props;
    if (this.rendition) {
      this.rendition.on("locationChanged", this.onLocationChange);
      this.rendition.on("keyup", handleKeyPress || this.handleKeyPress);
      if (handleTextSelected) {
        this.rendition.on("selected", handleTextSelected);
      }
      const {
        onPageTextExtracted,
        onPageParagraphsExtracted,
        onNextPageParagraphs,
        onPreviousPageParagraphs,
      } = this.props;
      if (
        onPageTextExtracted ||
        onPageParagraphsExtracted ||
        onNextPageParagraphs ||
        onPreviousPageParagraphs
      ) {
        this.rendition.on("relocated", () => {
          if (onPageTextExtracted) {
            const pageTextData = this.getCurrentPageText();
            onPageTextExtracted(pageTextData);
          }
          if (onPageParagraphsExtracted) {
            const pageParagraphsData = this.getCurrentPageParagraphs();
            onPageParagraphsExtracted(pageParagraphsData);
          }
          if (onNextPageParagraphs) {
            void this.getNextViewParagraphs().then((nextPageParagraphsData) => {
              onNextPageParagraphs(nextPageParagraphsData);
            });
          } else {
            void this.getNextViewParagraphs();
          }
          if (onPreviousPageParagraphs) {
            void this.getPreviousViewParagraphs().then(
              (previousPageParagraphsData) => {
                onPreviousPageParagraphs(previousPageParagraphsData);
              }
            );
          } else {
            void this.getPreviousViewParagraphs();
          }
        });
      }
    }
  }

  /**
   * Handle location changes in the book
   */
  onLocationChange = (loc: Location) => {
    const {
      location,
      locationChanged,
      onPageTextExtracted,
      onPageParagraphsExtracted,
      onNextPageParagraphs,
      onPreviousPageParagraphs,
    } = this.props;
    const newLocation = `${loc.start}`;
    if (location !== newLocation) {
      this.location = newLocation;
      locationChanged && locationChanged(newLocation);

      if (onPageTextExtracted) {
        const pageTextData = this.getCurrentPageText();
        onPageTextExtracted(pageTextData);
      }

      if (onPageParagraphsExtracted) {
        const pageParagraphsData = this.getCurrentPageParagraphs();
        onPageParagraphsExtracted(pageParagraphsData);
      }

      if (onNextPageParagraphs) {
        void this.getNextViewParagraphs().then((nextPageParagraphsData) => {
          onNextPageParagraphs(nextPageParagraphsData);
        });
      } else {
        void this.getNextViewParagraphs();
      }

      if (onPreviousPageParagraphs) {
        void this.getPreviousViewParagraphs().then(
          (previousPageParagraphsData) => {
            onPreviousPageParagraphs(previousPageParagraphsData);
          }
        );
      } else {
        void this.getPreviousViewParagraphs();
      }
    }
  };

  /**
   * Render the book container
   */
  renderBook() {
    const { epubViewStyles = defaultStyles } = this.props;
    return <div ref={this.viewerRef} style={epubViewStyles.view} />;
  }

  getCurrentPageText = () => {
    // Stub -- the Tauri version uses getCurrentViewText but it's not called in the component
    return { text: "" };
  };

  getCurrentPageParagraphs = () => {
    return this.getCurrentViewParagraphs();
  };

  getCurrentViewParagraphs = () => {
    try {
      if (!this.rendition) {
        return { paragraphs: [] };
      }

      const result = getCurrentViewParagraphs(this.rendition);

      const paragraphs: ParagraphWithCFI[] = result.map((item) => ({
        text: item.text || "",
        cfiRange: item.cfiRange || "",
      }));
      return { paragraphs };
    } catch (error) {
      console.warn("Error extracting paragraphs:", error);
      return { paragraphs: [] };
    }
  };

  getNextViewParagraphs = async () => {
    try {
      if (!this.rendition) {
        return { paragraphs: [] };
      }
      const result = await getNextViewParagraphs(this.rendition);

      const paragraphs: ParagraphWithCFI[] = result.map((item) => ({
        text: item.text || "",
        cfiRange: item.cfiRange || "",
      }));
      return { paragraphs };
    } catch (error) {
      console.warn("Error extracting next page paragraphs:", error);
      return { paragraphs: [] };
    }
  };

  getPreviousViewParagraphs = async () => {
    try {
      if (!this.rendition) {
        return { paragraphs: [] };
      }
      const result = await getPreviousViewParagraphs(this.rendition);

      const paragraphs: ParagraphWithCFI[] = result.map((item) => ({
        text: item.text || "",
        cfiRange: item.cfiRange || "",
      }));
      return { paragraphs };
    } catch (error) {
      console.warn("Error extracting previous page paragraphs:", error);
      return { paragraphs: [] };
    }
  };

  highlightParagraph = (cfiRange: string) => {
    if (this.rendition && cfiRange) {
      void highlightRange(this.rendition, cfiRange);
    }
  };

  removeHighlight = (cfiRange: string) => {
    if (this.rendition && cfiRange) {
      void removeHighlight(this.rendition, cfiRange);
    }
  };

  handleKeyPress = (event: KeyboardEvent) => {
    if (!this.props.handleKeyPress) {
      const send = useNavStore.getState().send;
      if (!send) return;
      if (event.key === "ArrowRight") {
        send({ type: "NEXT" });
      }
      if (event.key === "ArrowLeft") {
        send({ type: "PREV" });
      }
    }
  };

  render() {
    const { isLoaded, isError } = this.state;
    const {
      loadingView = null,
      errorView = null,
      epubViewStyles = defaultStyles,
    } = this.props;
    return (
      <div style={epubViewStyles.viewHolder}>
        {isLoaded && this.renderBook()}
        {!isLoaded && !isError && loadingView}
        {!isLoaded && isError && errorView}
      </div>
    );
  }
}
