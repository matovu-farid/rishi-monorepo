import React, { useEffect, useRef, useCallback } from "react";

import { useVirtualizer } from "@tanstack/react-virtual";

// Import required CSS for text and annotation layers
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";

import { elementScroll } from "@tanstack/react-virtual";
import type { VirtualizerOptions } from "@tanstack/react-virtual";
import {
  hasNavigatedToPageAtom,
  pageCountAtom,
  virtualizerAtom,
} from "../atoms/paragraph-atoms";
import { useAtomValue, useSetAtom } from "jotai";
import { PAGE_HEIGHT } from "../utils/constants";
import { Book } from "@/generated";
function easeInOutQuint(t: number) {
  return t < 0.5 ? 16 * t * t * t * t * t : 1 + 16 * --t * t * t * t * t;
}
export function useVirualization(
  scrollContainerRef: React.RefObject<HTMLDivElement | null>,
  book: Book
) {
  const initialPageIndexRef = useRef(
    Math.max(0, Number.parseInt(book.location, 10) - 1)
  );
  const numPages = useAtomValue(pageCountAtom);
  const setHasNavigatedToPage = useSetAtom(hasNavigatedToPageAtom);
  const estimatedPageHeight = PAGE_HEIGHT;
  const scrollingRef = useRef<number | null>(null);
  const initialOffsetRef = useRef(
    initialPageIndexRef.current * estimatedPageHeight
  );
  const setVirtualizer = useSetAtom(virtualizerAtom);
  const pageRefs = useRef(new Map<number, HTMLElement>());
  const hasRequestedInitialScroll = useRef(false);
  const scrollToFn: VirtualizerOptions<any, any>["scrollToFn"] =
    React.useCallback((offset, canSmooth, instance) => {
      const duration = 1000;
      const start = scrollContainerRef.current?.scrollTop || 0;
      const startTime = (scrollingRef.current = Date.now());

      const run = () => {
        if (scrollingRef.current !== startTime) return;
        const now = Date.now();
        const elapsed = now - startTime;
        const progress = easeInOutQuint(Math.min(elapsed / duration, 1));
        const interpolated = start + (offset - start) * progress;

        if (elapsed < duration) {
          elementScroll(interpolated, canSmooth, instance);
          requestAnimationFrame(run);
        } else {
          elementScroll(interpolated, canSmooth, instance);
        }
      };

      requestAnimationFrame(run);
    }, []);

  const virtualizer = useVirtualizer({
    count: numPages,
    getScrollElement: () => scrollContainerRef.current,
    estimateSize: () => estimatedPageHeight,
    overscan: 8,
    enabled: numPages > 0,
    initialOffset: initialOffsetRef.current,
    scrollToFn,
    gap: 32,
  });
  setVirtualizer(virtualizer);
  const handlePageRendered = useCallback(
    (index: number) => {
      setHasNavigatedToPage(true);
    },
    [virtualizer]
  );

  useEffect(() => {
    if (hasRequestedInitialScroll.current) return;
    if (numPages === 0) return;
    if (!scrollContainerRef.current) return;

    hasRequestedInitialScroll.current = true;
  }, [numPages, virtualizer]);

  const virtualItems = virtualizer.getVirtualItems();
  return { virtualizer, virtualItems, pageRefs, handlePageRendered };
}
