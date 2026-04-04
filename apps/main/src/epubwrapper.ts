import type { Book, Rendition } from "epubjs";
import type { BookOptions } from "epubjs/types/book";
import type View from "epubjs/types/managers/view";
import type Section from "epubjs/types/section";
//import type { SpineItem } from "epubjs/types/section";
import Epub, { EpubCFI, Contents } from "epubjs";
import { SpineItem } from "epubjs/types/section";
import { ChunkInsertable } from "./modules/kysley";
import { stringToNumberID } from "@components/lib/utils";

export type ParagraphWithCFI = {
  text: string;
  cfiRange: string;
  startCfi: string;
  endCfi: string;
};
// Overload 1: with urlOrData and optional options
export function initialize(
  urlOrData: string | ArrayBuffer,
  options?: BookOptions
): Book;

// Overload 2: with only optional options
export function initialize(options?: BookOptions): Book;

// Implementation
export function initialize(
  urlOrDataOrOptions?: string | ArrayBuffer | BookOptions,
  options?: BookOptions
): Book {
  let epub: Book;
  if (
    typeof urlOrDataOrOptions === "string" ||
    urlOrDataOrOptions instanceof ArrayBuffer
  ) {
    epub = Epub(urlOrDataOrOptions, options);
  } else {
    epub = Epub(urlOrDataOrOptions);
  }

  return epub;
}

export function getCurrentViewText(rendition: Rendition) {
  if (!rendition.manager) {
    return null;
  }

  // Get the current location which includes the visible range
  const location = rendition.manager.currentLocation();

  if (!location || !location.length || !location[0]) {
    return null;
  }

  // Get the first visible section's mapping which contains the CFI range
  const visibleSection = location[0];

  if (
    !visibleSection.mapping ||
    !visibleSection.mapping.start ||
    !visibleSection.mapping.end
  ) {
    return null;
  }

  // Find the view for this section
  const view = rendition.manager.views.find({ index: visibleSection.index });

  if (!view || !view.contents || !view.contents.document) {
    return null;
  }

  try {
    // Create CFI ranges for the visible page
    const startCfi = new EpubCFI(visibleSection.mapping.start);
    const endCfi = new EpubCFI(visibleSection.mapping.end);

    // Convert CFIs to DOM ranges
    const startRange = startCfi.toRange(view.contents.document);
    const endRange = endCfi.toRange(view.contents.document);

    if (!startRange || !endRange) {
      return null;
    }

    // Create a range that encompasses the visible content
    const range = view.contents.document.createRange();
    range.setStart(startRange.startContainer, startRange.startOffset);
    range.setEnd(endRange.endContainer, endRange.endOffset);

    // Extract text from the range
    const text = range.toString();

    return {
      text: text,
      startCfi: visibleSection.mapping.start,
      endCfi: visibleSection.mapping.end,
    };
  } catch (e) {
    console.error("Error extracting visible text:", e);
    return null;
  }
}

export function highlightRange(
  rendition: Rendition,
  cfiRange: string,
  data?: Record<string, unknown>,
  cb?: () => void,
  className = "epubjs-hl",
  styles?: Record<string, unknown>
) {
  if (!rendition.manager) {
    return Promise.reject(new Error("Rendition manager not available"));
  }

  try {
    // Parse the CFI range to validate it
    const rangeCfi = new EpubCFI(cfiRange);

    // Check if this is a range CFI (should have start and end)
    if (!rangeCfi.range) {
      return Promise.reject(
        new Error("CFI string is not a range: " + cfiRange)
      );
    }

    // Find the view that contains this CFI range
    const found = rendition.manager
      .visible()
      .filter((view: { index: any }) => rangeCfi.spinePos === view.index);

    if (!found.length) {
      return Promise.reject(
        new Error("No view found for CFI range: " + cfiRange)
      );
    }

    const view = found[0];
    if (!view.contents) {
      return Promise.reject(new Error("View contents not available"));
    }

    // Verify the CFI range can be converted to a DOM range
    const domRange = rangeCfi.toRange(
      view.contents.document,
      rendition.settings.ignoreClass
    );

    if (!domRange) {
      return Promise.reject(
        new Error("Could not convert CFI range to DOM range")
      );
    }

    // Apply default yellow highlight styles if no custom styles provided
    const defaultStyles = {
      fill: "yellow",
      // "fill-opacity": "0.5",
      // "mix-blend-mode": "screen",
    };
    const mergedStyles = Object.assign(defaultStyles, styles);
    const hash = encodeURI(cfiRange + "highlight");
    const annotationExists = hash in rendition.annotations._annotations;
    if (annotationExists) {
      return Promise.resolve(annotationExists);
    }
    // Use the existing highlight method with the CFI range
    // Pass the parsed EpubCFI instance as expected by the API
    const annotation = rendition.annotations.highlight(
      rangeCfi,
      data,
      cb || (() => {}),
      className,
      mergedStyles
    );

    // Return a resolved promise since highlight is synchronous
    return Promise.resolve(annotation);
  } catch (error) {
    return Promise.reject(
      new Error(
        "Error highlighting range: " +
          (error instanceof Error ? error.message : String(error))
      )
    );
  }
}

/**
 * Remove a highlight from a CFI range
 * @param {string} cfiRange - CFI range string to remove highlight from
 * @returns {Promise<boolean>} Promise that resolves to true if highlight was removed, false if not found
 */
export function removeHighlight(rendition: Rendition, cfiRange: string) {
  if (!rendition.manager) {
    return Promise.reject(new Error("Rendition manager not available"));
  }

  try {
    // Parse the CFI range to validate it
    const rangeCfi = new EpubCFI(cfiRange);

    // Check if this is a range CFI (should have start and end)
    if (!rangeCfi.range) {
      return Promise.reject(
        new Error("CFI string is not a range: " + cfiRange)
      );
    }

    // Find the view that contains this CFI range
    const found = rendition.manager.visible().filter(function (view: {
      index: any;
    }) {
      return rangeCfi.spinePos === view.index;
    });

    if (!found.length) {
      // If no view is found, the highlight might still exist in the store
      // but not be visible, so we can still try to remove it
      console.warn(
        "No visible view found for CFI range, attempting to remove from store: " +
          cfiRange
      );
    }

    // Check if the annotation exists before removal
    const hash = encodeURI(cfiRange + "highlight");
    const annotationExists = hash in rendition.annotations._annotations;
    // Remove the highlight annotation
    // Pass the parsed EpubCFI instance as expected by the API
    if (annotationExists) rendition.annotations.remove(rangeCfi, "highlight");

    // Return a resolved promise with the result
    return Promise.resolve(annotationExists);
  } catch (error) {
    return Promise.reject(
      new Error(
        "Error removing highlight: " +
          (error instanceof Error ? error.message : String(error))
      )
    );
  }
}

function _getTextNodesInRange(range: Range) {
  const textNodes: Node[] = [];

  try {
    // Validate range first
    if (!range || !range.commonAncestorContainer) {
      console.error("_getTextNodesInRange: Invalid range provided");
      return textNodes;
    }

    const walker =
      range.commonAncestorContainer.ownerDocument?.createTreeWalker(
        range.commonAncestorContainer,
        NodeFilter.SHOW_TEXT,
        {
          acceptNode: function (node) {
            try {
              // Skip empty or whitespace-only text nodes
              if (!node.textContent || !node.textContent.trim()) {
                return NodeFilter.FILTER_REJECT;
              }
              return range.intersectsNode(node)
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            } catch (e) {
              return NodeFilter.FILTER_REJECT;
            }
          },
        }
      );
    if (!walker) {
      return textNodes;
    }

    let node: Node | null;
    while ((node = walker.nextNode())) {
      textNodes.push(node);
    }
  } catch (e) {
    console.error("Error getting text nodes in range:", e);
  }

  return textNodes;
}

function _findContainingBlockElement(textNode: Node) {
  const blockSelectors =
    "p, div, h1, h2, h3, h4, h5, h6, li, blockquote, pre, article, section, aside, header, footer, main, nav, figure, figcaption, dd, dt";

  let element = textNode.parentElement;

  while (element) {
    try {
      if (element.matches && element.matches(blockSelectors)) {
        return element;
      }
    } catch (e) {
      // Fallback for older browsers
      const selectors = blockSelectors.split(", ");
      for (const selector of selectors) {
        try {
          if (element.matches && element.matches(selector)) {
            return element;
          }
        } catch (e2) {
          continue;
        }
      }
    }
    element = element.parentElement;
  }

  return null;
}
function getPosition(view: View) {
  const element = view?.element as HTMLDivElement;
  const iframe = element.querySelector("iframe");
  const position = iframe?.getBoundingClientRect();
  if (!position) {
    return null;
  }

  return {
    left: position.left,
    right: position.right,
    width: position.width,
    height: position.height,
  };
}
export async function getTotalPagesForBook(
  rendition: Rendition
): Promise<number> {
  const book = rendition.book;

  const sections: Section[] = await book.loaded.spine.then((spine: any) => {
    const sections = spine.spineItems;
    return sections;
  });

  const positions = (
    await Promise.all(
      sections.map(async (section) => {
        const view = await rendition.manager.add(section, false);

        return getPosition(view);
      })
    )
  )
    .filter((poisition) => poisition !== null)
    .sort((a, b) => a.right - b.right);
  const firstPosition = positions[0];
  if (!firstPosition) {
    return 0;
  }

  const lastPosition = positions[positions.length - 1];
  if (!lastPosition) {
    return 0;
  }

  const totalWidth = lastPosition.right - firstPosition.left;
  const pagesCount = totalWidth / rendition.manager.layout.width;
  console.log({ pagesCount });
  return pagesCount;
}

export async function getAllParagraphsForBook(
  rendition: Rendition,
  bookId: string
): Promise<ChunkInsertable[]> {
  const book = rendition.book;

  let sections: Section[] = await book.loaded.spine.then((spine: any) => {
    const sections = spine.spineItems;
    return sections;
  });
  sections = sections.sort((a, b) => a.index - b.index);
  const views = await Promise.all(
    sections.map(async (section) => {
      return await rendition.manager.add(section, false);
    })
  );

  const paragraphs = views
    .map((view) => {
      //  const view = await rendition.manager.add(section, false);
      const position = getPosition(view);
      if (!position) {
        return [];
      }
      // const position = view?.position();
      const mapping = getMapping(
        rendition,
        0,
        position.right - position.left,
        view
      );
      if (!mapping) return [];

      const paragraphs = reducePraragraphs(
        reducePraragraphs(
          getParagraphsFromMapping({
            rendition,
            startCfiString: mapping.start,
            endCfiString: mapping.end,
            view: view,
          })
        ),
        { direction: "backward" }
      ).map((paragraph) => ({
        ...paragraph,
        sectionId: view.section.index,
      }));

      return paragraphs;
    })

    .flat();

  try {
    rendition.manager.clear();
  } catch (error) {
    console.error("Error removing view:", error);
  }

  rendition.manager.updateLayout();
  // console.log(JSON.stringify(paragraphs, null, 2));

  const chunkData = paragraphs.map((paragraph) => ({
    data: paragraph.text,
    bookId: Number(bookId),
    pageNumber: paragraph.sectionId,
    id: stringToNumberID(
      bookId +
        "-" +
        paragraph.sectionId +
        "-" +
        paragraph.startCfi +
        "-" +
        paragraph.endCfi
    ),
  }));
  return chunkData;
}
function reducePraragraphs(
  paragraphs: ParagraphWithCFI[],
  options: {
    minLength?: number;
    direction?: "forward" | "backward";
  } = {
    minLength: 500,
    direction: "forward",
  }
): ParagraphWithCFI[] {
  const { minLength = 500, direction = "forward" } = options;

  return paragraphs.reduce((acc, paragraph) => {
    let pushed = paragraph;
    const isPreviousParagraphTooShort =
      acc.length > 0 &&
      acc[acc.length - 1].text.length < minLength &&
      direction === "backward";
    const isCurrentParagraphTooShort =
      acc.length > 0 &&
      paragraph.text.length < minLength &&
      direction === "forward";

    if (isPreviousParagraphTooShort || isCurrentParagraphTooShort) {
      const lastParagraph = acc.pop()!;

      lastParagraph.text += "\n" + paragraph.text;
      lastParagraph.endCfi = paragraph.endCfi;
      pushed = lastParagraph;
    }
    acc.push(pushed);
    return acc;
  }, [] as ParagraphWithCFI[]);
}
function _getParagraphsFromRange(
  rendition: Rendition,
  range: Range,
  contents: Contents
): ParagraphWithCFI[] {
  const paragraphs: ParagraphWithCFI[] = [];

  try {
    // Get the full text from the range (same as getCurrentViewText)
    const fullText = range.toString();

    if (!fullText.trim()) {
      return [];
    }

    // Get the document from the range
    const document = range.commonAncestorContainer.ownerDocument;
    if (!document) {
      return [];
    }

    // Find all text nodes within the range
    const textNodes = _getTextNodesInRange(range);

    if (textNodes.length === 0) {
      return [];
    }

    // Group text nodes by their containing block elements
    const blockElementToTextNodes = new Map();

    for (const textNode of textNodes) {
      const blockElement = _findContainingBlockElement(textNode);
      if (blockElement) {
        if (!blockElementToTextNodes.has(blockElement)) {
          blockElementToTextNodes.set(blockElement, []);
        }
        blockElementToTextNodes.get(blockElement).push(textNode);
      }
    }

    // Create paragraphs from grouped text nodes
    for (const [blockElement, textNodes] of blockElementToTextNodes) {
      try {
        // Extract text from these specific text nodes
        let elementText = "";
        let firstTextNode = null;
        let lastTextNode = null;
        let firstTextOffset = 0;
        let lastTextOffset = 0;

        for (const textNode of textNodes) {
          const nodeText = textNode.textContent || "";

          // Track first and last text nodes for range creation
          if (!firstTextNode) {
            firstTextNode = textNode;
          }
          lastTextNode = textNode;

          // Check if this is the same node as both start and end container
          if (
            textNode === range.startContainer &&
            textNode === range.endContainer
          ) {
            elementText += nodeText.substring(
              range.startOffset,
              range.endOffset
            );
            firstTextOffset = range.startOffset;
            lastTextOffset = range.endOffset;
          }
          // If this is the start node, trim from the beginning
          else if (textNode === range.startContainer) {
            elementText += nodeText.substring(range.startOffset);
            firstTextOffset = range.startOffset;
            // If this is also the last node, set lastTextOffset
            if (textNode === lastTextNode) {
              lastTextOffset = nodeText.length;
            }
          }
          // If this is the end node, trim from the end
          else if (textNode === range.endContainer) {
            elementText += nodeText.substring(0, range.endOffset);
            lastTextOffset = range.endOffset;
            // If this is also the first node, set firstTextOffset
            if (textNode === firstTextNode) {
              firstTextOffset = 0;
            }
          }
          // Otherwise, include the full text (middle node)
          else {
            elementText += nodeText;
            // If this is the first node, set firstTextOffset
            if (textNode === firstTextNode) {
              firstTextOffset = 0;
            }
            // If this is the last node, set lastTextOffset
            if (textNode === lastTextNode) {
              lastTextOffset = nodeText.length;
            }
          }
        }

        // Don't normalize whitespace here - preserve original spacing
        // The normalization should happen at the test level for comparison
        elementText = elementText.trim();

        // Skip empty paragraphs
        if (!elementText || !firstTextNode || !lastTextNode) {
          continue;
        }

        // Create a DOM Range for the paragraph's actual text content
        const paragraphRange = document.createRange();

        // Validate offsets before setting range boundaries
        const maxStartOffset = firstTextNode.textContent
          ? firstTextNode.textContent.length
          : 0;
        const maxEndOffset = lastTextNode.textContent
          ? lastTextNode.textContent.length
          : 0;

        // Ensure offsets are within valid bounds
        const validFirstOffset = Math.min(
          Math.max(firstTextOffset, 0),
          maxStartOffset
        );
        const validLastOffset = Math.min(
          Math.max(lastTextOffset, 0),
          maxEndOffset
        );

        // Set start to the beginning of the first text node (accounting for trimming)
        paragraphRange.setStart(firstTextNode, validFirstOffset);

        // Set end to the end of the last text node (accounting for trimming)
        paragraphRange.setEnd(lastTextNode, validLastOffset);

        // Generate CFI for the block element itself to ensure uniqueness
        // This creates a single-point CFI that uniquely identifies this paragraph element
        const elementCfi = new EpubCFI(
          blockElement,
          contents.cfiBase,
          rendition.settings.ignoreClass
        );

        let startCfi: string, endCfi: string, cfiRange: string;

        // For paragraphs, we treat each as a single element with the same start and end CFI
        // This matches the test expectation that startCfi === endCfi for single paragraphs
        const mainCfi = elementCfi.toString();
        startCfi = mainCfi;
        endCfi = mainCfi;

        // For highlighting, we can use the range CFI that spans the text content
        const rangeCfiObj = new EpubCFI(
          paragraphRange,
          contents.cfiBase,
          rendition.settings.ignoreClass
        );
        cfiRange = rangeCfiObj.toString();

        paragraphs.push({
          text: elementText,
          startCfi: startCfi,
          endCfi: endCfi,
          cfiRange: cfiRange, // Add full range CFI for highlighting
        });
      } catch (e) {
        console.error("❌ Error processing block element:", e);
        continue;
      }
    }

    // Fallback: if no paragraphs found but we have text, create one paragraph from entire range
    if (paragraphs.length === 0 && fullText.trim()) {
      try {
        const cfi = new EpubCFI(
          range,
          contents.cfiBase,
          rendition.settings.ignoreClass
        );
        const cfiString = cfi.toString();
        paragraphs.push({
          text: fullText.trim(),
          cfiRange: cfiString,
          startCfi: cfiString,
          endCfi: cfiString,
        });
      } catch (e) {
        console.error("Error creating fallback paragraph:", e);
      }
    }

    return paragraphs;
  } catch (e) {
    console.error("Error getting paragraphs from range:", e);
    return [];
  }
}

function getCurrentLocationPosition(rendition: Rendition) {
  const manager = rendition.manager;
  let visible = manager.visible();
  let container = manager.container.getBoundingClientRect();

  let scrolledX = 0;
  let pixelsUsedByPreviousPages = 0;

  if (manager.settings.fullsize) {
    scrolledX = window.scrollX;
  }
  if (visible.length === 0) {
    return null;
  }
  const view = visible[0];

  let { index, href } = view.section;
  let globalViewPortPosition;
  let globalChapterPosition = view.position();

  // Find mapping
  let localViewPortStartPosition;
  let localViewPortEndPosition;
  let pageWidth;

  if (manager.settings.direction === "rtl") {
    globalViewPortPosition = container.right - scrolledX;
    pageWidth =
      Math.min(
        Math.abs(globalViewPortPosition - globalChapterPosition.left),
        manager.layout.width
      ) - pixelsUsedByPreviousPages;
    localViewPortEndPosition =
      globalChapterPosition.width -
      (globalChapterPosition.right - globalViewPortPosition) -
      pixelsUsedByPreviousPages;
    localViewPortStartPosition = localViewPortEndPosition - pageWidth;
  } else {
    globalViewPortPosition = container.left + scrolledX;
    pageWidth =
      Math.min(
        globalChapterPosition.right - globalViewPortPosition,
        manager.layout.width
      ) - pixelsUsedByPreviousPages;
    localViewPortStartPosition =
      globalViewPortPosition -
      globalChapterPosition.left +
      pixelsUsedByPreviousPages;
    localViewPortEndPosition = localViewPortStartPosition + pageWidth;
  }

  pixelsUsedByPreviousPages += pageWidth;

  return {
    index,
    href,
    localViewPortStartPosition,
    localViewPortEndPosition,
  };
}

function getMapping(
  rendition: Rendition,
  localViewPortStartPosition: number,
  localViewPortEndPosition: number,
  view: View
) {
  if (!view || !view.contents || !view.contents.document) {
    return null;
  }
  const manager = rendition.manager;
  let mapping = manager.mapping.page(
    view.contents,
    view.section.cfiBase,
    localViewPortStartPosition,
    localViewPortEndPosition
  );

  return mapping;
}

export function getCurrentView(rendition: Rendition) {
  const location = rendition.manager.currentLocation();

  if (!location || !location.length || !location[0]) {
    return null;
  }

  const visibleSection = location[0];

  if (
    !visibleSection.mapping ||
    !visibleSection.mapping.start ||
    !visibleSection.mapping.end
  ) {
    return null;
  }
  const index = visibleSection.index;
  const view = rendition.manager.views.find({ index });
  return view || null;
}

export function getCurrentIndex(rendition: Rendition) {
  const location = rendition.manager.currentLocation();

  if (!location || !location.length || !location[0]) {
    return null;
  }

  const visibleSection = location[0];

  if (
    !visibleSection.mapping ||
    !visibleSection.mapping.start ||
    !visibleSection.mapping.end
  ) {
    return null;
  }
  const index = visibleSection.index;

  return index;
}
export function getCurrentViewParagraphs(
  rendition: Rendition
): ParagraphWithCFI[] {
  if (!rendition.manager) {
    return [];
  }
  const locationPosition = getCurrentLocationPosition(rendition);

  if (!locationPosition) {
    return [];
  }
  const view = getCurrentView(rendition);
  if (!view) {
    return [];
  }

  const mapping = getMapping(
    rendition,
    locationPosition.localViewPortStartPosition,
    locationPosition.localViewPortEndPosition,
    view
  );
  if (!mapping) {
    return [];
  }

  return getParagraphsFromMapping({
    rendition,

    startCfiString: mapping.start,
    endCfiString: mapping.end,
  });
}

/**
 * Polls for a view to be created by epubjs after a section is loaded.
 * Checks repeatedly until the view exists or the maximum wait time is reached.
 * @param rendition - The epubjs Rendition instance
 * @param sectionIndex - The index of the section to find the view for
 * @param maxWaitTimeMs - Maximum time to wait in milliseconds (default: 2000)
 * @param pollIntervalMs - Interval between checks in milliseconds (default: 50)
 * @returns The View if found, null otherwise
 */
async function pollForViewToBeCreated(
  rendition: Rendition,
  sectionIndex: number,
  maxWaitTimeMs: number = 2000,
  pollIntervalMs: number = 50
): Promise<View | null> {
  const startTime = Date.now();

  while (Date.now() - startTime < maxWaitTimeMs) {
    const view = rendition.manager.views.find({ index: sectionIndex });
    if (view) {
      return view;
    }

    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }

  return null;
}

async function getViewFromSpineItem(
  spineItem: SpineItem,
  rendition: Rendition
) {
  const loadPromise = spineItem.load(rendition.book.load.bind(rendition.book));

  const timeoutPromise = new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error("Section load timeout")), 10000)
  );

  const loadedSection = (await Promise.race([
    loadPromise,
    timeoutPromise,
  ])) as Section;

  // if (!loadedSection || !loadedSection.document) {
  //   return null;
  // }
  //console.log(">>> loadedSection", loadedSection);
  let view = rendition.manager.views.find({ index: spineItem.index });
  if (view) {
    return view;
  }

  view = rendition.manager.views.find({ index: loadedSection.index });
  if (view) {
    return view;
  }

  // If view doesn't exist yet, poll for it
  // epubjs might need time to create the view after loading the section
  view =
    (await pollForViewToBeCreated(rendition, spineItem.index)) || undefined;
  if (view) {
    return view;
  }

  view =
    (await pollForViewToBeCreated(rendition, loadedSection.index)) || undefined;
  return view;
}

function clampedToChapterLocalDimentions(localPosition: number, chapter: View) {
  const localCurrentChapterEnd =
    chapter.position().right - chapter.position().left;
  if (localPosition > localCurrentChapterEnd) {
    return localCurrentChapterEnd;
  }
  if (localPosition < 0) {
    return 0;
  }
  return localPosition;
}

type LocationPosition = {
  index: number;
  href: string;
  localViewPortStartPosition: number;
  localViewPortEndPosition: number;
};

type ViewParagraphsSetup = {
  locationPosition: LocationPosition;
  viewPortWidth: number;
  view: View;
};

function _getViewParagraphsSetup(
  rendition: Rendition
): ViewParagraphsSetup | null {
  if (!rendition.manager) {
    return null;
  }
  const locationPosition = getCurrentLocationPosition(rendition);
  if (!locationPosition) {
    return null;
  }
  const viewPortWidth = rendition.manager.layout.width;
  const view = getCurrentView(rendition);
  if (!view) {
    return null;
  }
  return {
    locationPosition: locationPosition as LocationPosition,
    viewPortWidth,
    view,
  };
}

async function _loadSectionParagraphsForUnloadedView(
  spineItem: SpineItem,
  rendition: Rendition,
  start: number,
  end: number
): Promise<ParagraphWithCFI[]> {
  try {
    const loadPromise = spineItem.load(
      rendition.book.load.bind(rendition.book)
    );
    const timeoutPromise = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error("Section load timeout")), 10000)
    );

    const loadedSection = (await Promise.race([
      loadPromise,
      timeoutPromise,
    ])) as Section;

    if (!loadedSection || !loadedSection.document) {
      return [];
    }

    const document = loadedSection.document;
    const body = document.body;

    if (!body) {
      return [];
    }

    // Create a Contents object from the loaded section
    const contents = new Contents(
      document,
      body,
      spineItem.cfiBase,
      spineItem.index
    );

    const mapping = rendition.manager.mapping.page(
      contents,
      spineItem.cfiBase,
      start,
      end
    );

    if (!mapping || !mapping.start || !mapping.end) {
      return [];
    }

    // Convert CFIs to DOM ranges
    const startCfi = new EpubCFI(mapping.start);
    const endCfi = new EpubCFI(mapping.end);

    const startRange = startCfi.toRange(document);
    const endRange = endCfi.toRange(document);

    if (!startRange || !endRange) {
      return [];
    }

    // Create a range that encompasses the content
    const range = document.createRange();
    range.setStart(startRange.startContainer, startRange.startOffset);
    range.setEnd(endRange.endContainer, endRange.endOffset);

    // Extract paragraphs from the range
    return _getParagraphsFromRange(rendition, range, contents);
  } catch (e) {
    console.error("Error loading section content:", e);
    return [];
  }
}

async function _getAdjacentViewParagraphs(
  rendition: Rendition,
  direction: "next" | "previous",
  setup: ViewParagraphsSetup
): Promise<ParagraphWithCFI[]> {
  const { locationPosition, viewPortWidth, view } = setup;

  // Get the adjacent spine item based on direction
  const adjacentSpineItem =
    direction === "next" ? view.section.next() : view.section.prev();

  // Try to get the view for the adjacent section
  const secondChapter = adjacentSpineItem
    ? await getViewFromSpineItem(adjacentSpineItem, rendition).catch(() => null)
    : null;

  // Calculate first chapter positions (offset by viewport width in the appropriate direction)
  const positionOffset = direction === "next" ? viewPortWidth : -viewPortWidth;
  const firstChapterStart = clampedToChapterLocalDimentions(
    locationPosition.localViewPortStartPosition + positionOffset,
    view
  );
  const firstChapterEnd = clampedToChapterLocalDimentions(
    locationPosition.localViewPortEndPosition + positionOffset,
    view
  );
  const firstChapterWidth = firstChapterEnd - firstChapterStart;
  const remainingWidthForSecondChapter = viewPortWidth - firstChapterWidth;

  // Handle loading paragraphs from unloaded view (for previous direction special case)
  let secondChapterParagraphs: ParagraphWithCFI[] = [];
  if (
    !secondChapter &&
    adjacentSpineItem &&
    remainingWidthForSecondChapter > 0 &&
    direction === "previous"
  ) {
    try {
      const loadPromise = adjacentSpineItem.load(
        rendition.book.load.bind(rendition.book)
      );
      const timeoutPromise = new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error("Section load timeout")), 10000)
      );

      const loadedSection = (await Promise.race([
        loadPromise,
        timeoutPromise,
      ])) as Section;

      if (loadedSection && loadedSection.document) {
        const document = loadedSection.document;
        const body = document.body;

        if (body) {
          // Get dimensions
          const totalWidth =
            rendition.manager.settings.axis === "horizontal"
              ? body.scrollWidth
              : body.scrollHeight;

          const start = Math.max(
            0,
            totalWidth - remainingWidthForSecondChapter
          );
          const end = totalWidth;

          secondChapterParagraphs = await _loadSectionParagraphsForUnloadedView(
            adjacentSpineItem,
            rendition,
            start,
            end
          );
        }
      }
    } catch (e) {
      console.error("Error loading previous section content:", e);
    }
  }

  // Calculate second chapter positions
  let secondChapterStart = 0;
  let secondChapterEnd = 0;

  if (secondChapter) {
    if (direction === "next") {
      // For next: start at 0, end at the width we need
      secondChapterEnd = clampedToChapterLocalDimentions(
        remainingWidthForSecondChapter,
        secondChapter
      );
      secondChapterStart = 0;
    } else {
      // For previous: start from the end, working backwards
      const secondChapterLocalEnd =
        secondChapter.position().right - secondChapter.position().left;
      secondChapterEnd = secondChapterLocalEnd;
      secondChapterStart = clampedToChapterLocalDimentions(
        secondChapterLocalEnd - remainingWidthForSecondChapter,
        secondChapter
      );
    }
  }

  // Build positions array
  let positions: ParagraphPosition[] = [
    {
      start: firstChapterStart,
      end: firstChapterEnd,
      view: view,
    },
  ];

  if (secondChapter && secondChapterEnd > secondChapterStart) {
    positions.push({
      start: secondChapterStart,
      end: secondChapterEnd,
      view: secondChapter,
    });
  }

  // Filter out invalid positions
  positions = positions.filter((position) => position.end > position.start);

  // Create paragraphs from positions
  const paragraphsFromPositions = createParagraphsFromPostions(
    positions,
    rendition
  );

  // If we got paragraphs from the loaded section directly, include them
  if (secondChapterParagraphs.length > 0) {
    return [...secondChapterParagraphs, ...paragraphsFromPositions];
  }

  return paragraphsFromPositions;
}

export async function getNextViewParagraphs(
  rendition: Rendition
): Promise<ParagraphWithCFI[]> {
  const setup = _getViewParagraphsSetup(rendition);
  if (!setup) {
    return [];
  }

  return _getAdjacentViewParagraphs(rendition, "next", setup);
}
type ParagraphPosition = {
  start: number;
  end: number;
  view: View;
};
function createParagraphsFromPostions(
  positions: ParagraphPosition[],
  rendition: Rendition
): ParagraphWithCFI[] {
  const paragraphs: ParagraphWithCFI[] = [];
  for (const position of positions) {
    const mapping = getMapping(
      rendition,
      position.start,
      position.end,
      position.view
    );

    if (!mapping) {
      continue;
    }

    const paragraphsGot = getParagraphsFromMapping({
      rendition,

      startCfiString: mapping.start,
      endCfiString: mapping.end,
      view: position.view,
    });
    paragraphs.push(...paragraphsGot);
  }

  return paragraphs;
}
export async function navigateToPage() {}
export async function getPreviousViewParagraphs(
  rendition: Rendition
): Promise<ParagraphWithCFI[]> {
  const setup = _getViewParagraphsSetup(rendition);
  if (!setup) {
    return [];
  }

  return _getAdjacentViewParagraphs(rendition, "previous", setup);
}

export function getParagraphsFromMapping({
  rendition,
  startCfiString,
  endCfiString,
  view: providedView,
}: {
  rendition: Rendition;

  startCfiString: string;
  endCfiString: string;
  view?: View;
}) {
  // Use provided view or find the view for this section
  const view = providedView || getCurrentView(rendition);
  if (!view) {
    return [];
  }

  if (!view || !view.contents || !view.contents.document) {
    return [];
  }

  try {
    // Create CFI ranges for the visible page
    const startCfi = new EpubCFI(startCfiString);
    const endCfi = new EpubCFI(endCfiString);

    // Convert CFIs to DOM ranges
    const startRange = startCfi.toRange(view.contents.document);
    const endRange = endCfi.toRange(view.contents.document);

    if (!startRange || !endRange) {
      return [];
    }

    // Create a range that encompasses the visible content
    const range = view.contents.document.createRange();
    range.setStart(startRange.startContainer, startRange.startOffset);
    range.setEnd(endRange.endContainer, endRange.endOffset);

    // Extract paragraphs from the range
    const paragraphs = _getParagraphsFromRange(rendition, range, view.contents);
    return paragraphs;
  } catch (e) {
    console.error("Error extracting paragraphs:", e);
    return [];
  }
}
