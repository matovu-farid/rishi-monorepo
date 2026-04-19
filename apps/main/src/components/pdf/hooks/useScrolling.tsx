import { useEffect, useRef } from "react";
import { animate } from "framer-motion";
import { usePlayerStore } from "@/stores/playerStore";

import { usePdfStore } from "@/stores/pdfStore";

export function useScrolling(
  scrollContainerRef: React.RefObject<HTMLDivElement | null>
) {
  const highlightedParagraphIndex = usePdfStore((s) => s.highlightedParagraphIndex);
  const currentViewParagraphs = usePdfStore((s) => s.currentViewParagraphs);
  const highlightedParagraph = currentViewParagraphs.find((p) => p.index === highlightedParagraphIndex);
  const isRendered = usePdfStore((s) => s.isTextGot);

  // Track whether we paused the player due to user scroll
  const pausedByScrollRef = useRef(false);
  const scrollDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Detect user-initiated scroll (wheel/touch) and pause/resume player.
  // We listen for wheel/touchmove rather than the generic "scroll" event so
  // that programmatic scrollTop changes (from our own animate() or the
  // virtualizer) don't accidentally pause the player.
  useEffect(() => {
    const container = scrollContainerRef.current;
    if (!container) return;

    const handleUserScroll = () => {
      const { playingState, send } = usePlayerStore.getState();

      if (playingState === "playing" && !pausedByScrollRef.current) {
        send?.({ type: "PAUSE" });
        pausedByScrollRef.current = true;
      }

      // Reset the debounce timer on every scroll event
      if (scrollDebounceRef.current) {
        clearTimeout(scrollDebounceRef.current);
      }

      // Once scrolling settles, resume the player
      scrollDebounceRef.current = setTimeout(() => {
        if (pausedByScrollRef.current) {
          pausedByScrollRef.current = false;
          usePlayerStore.getState().send?.({ type: "RESUME" });
        }
      }, 300);
    };

    container.addEventListener("wheel", handleUserScroll, { passive: true });
    container.addEventListener("touchmove", handleUserScroll, { passive: true });

    return () => {
      container.removeEventListener("wheel", handleUserScroll);
      container.removeEventListener("touchmove", handleUserScroll);
      if (scrollDebounceRef.current) {
        clearTimeout(scrollDebounceRef.current);
      }
      // If we paused the player and the component unmounts, resume it
      if (pausedByScrollRef.current) {
        pausedByScrollRef.current = false;
        usePlayerStore.getState().send?.({ type: "RESUME" });
      }
    };
  }, []);

  // Auto-scroll to the highlighted paragraph
  useEffect(() => {
    const container = scrollContainerRef.current;
    if (!container || !highlightedParagraph?.index) return;

    // Gate until that page's text layer has been rendered
    if (!isRendered) return;

    const timeout = setTimeout(() => {
      // Don't auto-scroll while the user is actively scrolling
      if (pausedByScrollRef.current) return;

      const el = [...container.querySelectorAll<HTMLElement>("mark")].find(
        (mark) => mark.innerText
      );
      if (!el) return;
      console.log({ el });
      const isLookingForNextParagraph = usePdfStore.getState().isLookingForNextParagraph;
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
