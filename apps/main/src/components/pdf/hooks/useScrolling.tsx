import { useEffect, useRef } from "react";
import { animate } from "framer-motion";

import {
  highlightedParagraphAtom,
  isLookingForNextParagraphAtom,
  isTextGotAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";
import { customStore } from "@/stores/jotai";
export function useScrolling(
  scrollContainerRef: React.RefObject<HTMLDivElement | null>
) {
  const highlightedParagraph = useAtomValue(highlightedParagraphAtom);
  const isRendered = useAtomValue(isTextGotAtom);
  useEffect(() => {
    const container = scrollContainerRef.current;
    if (!container || !highlightedParagraph?.index) return;

    // Gate until that page's text layer has been rendered
    if (!isRendered) return;

    const timeout = setTimeout(() => {
      const el = [...container.querySelectorAll<HTMLElement>("mark")].find(
        (mark) => mark.innerText
      );
      if (!el) return;
      console.log({ el });
      const isLookingForNextParagraph = customStore.get(
        isLookingForNextParagraphAtom
      );
      if (isLookingForNextParagraph) {
        return;
      }

      // Calculate the target scroll position
      const containerRect = container.getBoundingClientRect();
      const elementRect = el.getBoundingClientRect();

      // Current scroll position + element's position relative to container
      const currentScrollTop = container.scrollTop;
      const elementTopRelativeToContainer =
        elementRect.top - containerRect.top + currentScrollTop;

      // Calculate target scroll position to center the element
      const targetScrollTop =
        elementTopRelativeToContainer -
        container.clientHeight / 2 +
        elementRect.height / 2;

      // Use framer-motion's animate for smooth scrolling
      animate(container.scrollTop, targetScrollTop, {
        duration: 0.8,
        ease: [0.4, 0, 0.2, 1], // Custom easing curve for smoother feel
        onUpdate: (latest) => {
          container.scrollTop = latest;
        },
      });
    }, 100);
    return () => clearTimeout(timeout);
  }, [highlightedParagraph, isRendered]);
}
