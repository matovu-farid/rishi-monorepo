// import { customStore } from "@/stores/jotai";
// import {
//   ParagraphWithIndex,
//   PlayerControlEvent,
//   PlayerControlEventMap,
//   PlayerControlInterface,
// } from "./player_control";
// import {
//   getCurrentViewParagraphsAtom,
//   getNextViewParagraphsAtom,
//   getPreviousViewParagraphsAtom,
//   highlightedParagraphAtom,
//   highlightedParagraphIndexAtom,
//   isHighlightingAtom,
//   nextPageAtom,
//   pageNumberAtom,
//   previousPageAtom,
// } from "@components/pdf/atoms/paragraph-atoms";
// import { EventEmitter } from "eventemitter3";

// class PdfPlayerControl
//   extends EventEmitter<PlayerControlEventMap>
//   implements PlayerControlInterface
// {
//   private currentViewParagraphs: ParagraphWithIndex[] = [];
//   private nextPageParagraphs: ParagraphWithIndex[] = [];
//   private previousPageParagraphs: ParagraphWithIndex[] = [];

//   private currentlyHighlightedParagraphIndex: string | null = null;

//   constructor() {
//     super();
//     void this.initialize();
//   }

//   async initialize(): Promise<void> {
//     // Store unsubscribe functions for all subscriptions
//     // Note: customStore.sub() returns an unsubscribe function in Jotai
//     customStore.sub(pageNumberAtom, () => {
//       this.emit(PlayerControlEvent.PAGE_CHANGED);
//     });
//     const updateCurrent = () => {
//       const paragraphs = customStore.get(getCurrentViewParagraphsAtom);
//       this.currentViewParagraphs = paragraphs;
//       this.emit(PlayerControlEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);
//     };
//     const updateNext = () => {
//       const paragraphs = customStore.get(getNextViewParagraphsAtom);
//       this.nextPageParagraphs = paragraphs;
//       this.emit(PlayerControlEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, paragraphs);
//     };
//     const updatePrevious = () => {
//       const paragraphs = customStore.get(getPreviousViewParagraphsAtom);
//       this.previousPageParagraphs = paragraphs;
//       this.emit(
//         PlayerControlEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE,
//         paragraphs
//       );
//     };
//     const updateHighlightedParagraph = () => {
//       const highlightedParagraph = customStore.get(highlightedParagraphAtom);
//       if (highlightedParagraph) {
//         this.emit(
//           PlayerControlEvent.PARAGRAPH_HIGHLIGHTED,
//           highlightedParagraph
//         );
//       }
//     };
//     customStore.sub(getCurrentViewParagraphsAtom, updateCurrent);
//     updateCurrent();

//     customStore.sub(getNextViewParagraphsAtom, updateNext);
//     updateNext();
//     customStore.sub(getPreviousViewParagraphsAtom, updatePrevious);
//     updatePrevious();
//     customStore.sub(highlightedParagraphAtom, updateHighlightedParagraph);
//     updateHighlightedParagraph();
//     // Register event handlers (only called once in constructor, so no need to clean up old ones)
//     this.on(PlayerControlEvent.REMOVE_HIGHLIGHT, (index: string) => {
//       void this.removeHighlight(index);
//     });

//     this.on(PlayerControlEvent.HIGHLIGHT_PARAGRAPH, (index: string) => {
//       void this.highlightParagraph(index);
//     });

//     this.on(PlayerControlEvent.MOVE_TO_NEXT_PAGE, () => {
//       void this.moveToNextPage();
//       this.emit(PlayerControlEvent.PAGE_CHANGED);
//     });

//     this.on(PlayerControlEvent.MOVE_TO_PREVIOUS_PAGE, () => {
//       void this.moveToPreviousPage();
//       this.emit(PlayerControlEvent.PAGE_CHANGED);
//     });
//   }

//   async removeHighlight(index: string): Promise<void> {
//     customStore.set(isHighlightingAtom, false);
//     if (this.currentlyHighlightedParagraphIndex === index) {
//       this.currentlyHighlightedParagraphIndex = null;
//     }
//   }

//   async highlightParagraph(index: string): Promise<void> {
//     // Track currently highlighted paragraph to prevent duplicates
//     if (this.currentlyHighlightedParagraphIndex === index) {
//       return;
//     }
//     this.currentlyHighlightedParagraphIndex = index;
//     return customStore.set(highlightedParagraphIndexAtom, index);
//   }

//   async moveToNextPage() {
//     await customStore.set(nextPageAtom);
//   }

//   async moveToPreviousPage() {
//     await customStore.set(previousPageAtom);
//   }

//   cleanup(): void {
//     // Only remove listeners that this class registered, not all listeners
//     // We need to be careful not to remove listeners added by other classes (like Player)
//     // Since initialize() is only called once in constructor, we don't need to remove these
//     // unless we're doing a full cleanup/teardown

//     // Clear current highlight state
//     if (this.currentlyHighlightedParagraphIndex) {
//       customStore.set(isHighlightingAtom, false);
//       this.currentlyHighlightedParagraphIndex = null;
//     }
//   }
// }

// export const playerControl = new PdfPlayerControl();
