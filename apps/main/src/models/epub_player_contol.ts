import {
  PlayerControlEvent,
  PlayerControlEventMap,
  PlayerControlInterface,
} from "./player_control";

import type Rendition from "epubjs/types/rendition";

// @ts-ignore

import { highlightRange, removeHighlight } from "@/epubwrapper";
import { EventEmitter } from "eventemitter3";
import { customStore } from "@/stores/jotai";
import {
  currentEpubLocationAtom,
  getEpubCurrentViewParagraphsAtom,
  getEpubNextViewParagraphsAtom,
  getEpubPreviousViewParagraphsAtom,
  renditionAtom,
} from "@/stores/epub_atoms";

export class EpubPlayerControl
  extends EventEmitter<PlayerControlEventMap>
  implements PlayerControlInterface
{
  private currentlyHighlightedParagraphIndex: string | null = null;
  private currentRendition: Rendition | null = null;
  private renderedHandler: (() => Promise<void>) | null = null;
  private unsubscribeRendition: (() => void) | null = null;

  constructor() {
    super();
    void this.initialize();
  }

  async initialize(): Promise<void> {
    customStore.sub(getEpubCurrentViewParagraphsAtom, async () => {
      this.emit(
        PlayerControlEvent.NEW_PARAGRAPHS_AVAILABLE,
        await customStore.get(getEpubCurrentViewParagraphsAtom)
      );
    });

    customStore.sub(getEpubNextViewParagraphsAtom, async () => {
      this.emit(
        PlayerControlEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE,
        await customStore.get(getEpubNextViewParagraphsAtom)
      );
    });

    customStore.sub(getEpubPreviousViewParagraphsAtom, async () => {
      this.emit(
        PlayerControlEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE,
        await customStore.get(getEpubPreviousViewParagraphsAtom)
      );
    });
    // Store the unsubscribe function
    this.unsubscribeRendition = customStore.sub(renditionAtom, () => {
      const rendition = customStore.get(renditionAtom);

      if (rendition) {
        // Clean up old rendition listeners if we had a previous rendition
        if (this.currentRendition && this.renderedHandler) {
          this.currentRendition.off("rendered", this.renderedHandler);
        }

        // Clean up old event listeners on this instance
        this.removeAllListeners(PlayerControlEvent.MOVE_TO_NEXT_PAGE);
        this.removeAllListeners(PlayerControlEvent.MOVE_TO_PREVIOUS_PAGE);
        this.removeAllListeners(PlayerControlEvent.HIGHLIGHT_PARAGRAPH);
        this.removeAllListeners(PlayerControlEvent.REMOVE_HIGHLIGHT);

        // Store the new rendition
        this.currentRendition = rendition;

        // Register event handlers (only once per rendition change)
        this.on(PlayerControlEvent.MOVE_TO_NEXT_PAGE, async () => {
          await rendition.next();

          customStore.set(
            currentEpubLocationAtom,
            customStore.get(currentEpubLocationAtom) + 1
          );
          // Wait for rendered event to fire before emitting PAGE_CHANGED
          // This ensures paragraphs are updated before Player handles the page change

          this.emit(PlayerControlEvent.PAGE_CHANGED);
        });
        this.on(PlayerControlEvent.MOVE_TO_PREVIOUS_PAGE, async () => {
          await rendition.prev();

          // Wait for rendered event to fire before emitting PAGE_CHANGED

          this.emit(PlayerControlEvent.PAGE_CHANGED);
        });
        this.on(
          PlayerControlEvent.HIGHLIGHT_PARAGRAPH,
          async (index: string) => {
            // Remove old highlight before adding new one
            if (
              this.currentlyHighlightedParagraphIndex &&
              this.currentlyHighlightedParagraphIndex !== index
            ) {
              await removeHighlight(
                rendition,
                this.currentlyHighlightedParagraphIndex
              );
            }
            // Only highlight if it's not already highlighted
            if (this.currentlyHighlightedParagraphIndex !== index) {
              await highlightRange(rendition, index);
              this.currentlyHighlightedParagraphIndex = index;
            }
          }
        );
        this.on(PlayerControlEvent.REMOVE_HIGHLIGHT, async (index: string) => {
          await removeHighlight(rendition, index);
          if (this.currentlyHighlightedParagraphIndex === index) {
            this.currentlyHighlightedParagraphIndex = null;
          }
        });
      }
    });
  }

  cleanup(): void {
    // Clean up rendition listener
    if (this.currentRendition && this.renderedHandler) {
      this.currentRendition.off("rendered", this.renderedHandler);
    }

    // Unsubscribe from rendition atom
    if (this.unsubscribeRendition) {
      this.unsubscribeRendition();
    }

    // Remove all event listeners
    this.removeAllListeners();

    // Clear current highlight
    if (this.currentlyHighlightedParagraphIndex && this.currentRendition) {
      void removeHighlight(
        this.currentRendition,
        this.currentlyHighlightedParagraphIndex
      );
      this.currentlyHighlightedParagraphIndex = null;
    }
  }
}

export const epubPlayerControl = new EpubPlayerControl();
