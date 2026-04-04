// --------------------------------------------------------------------------------------
// Hook utilities and helpers for tracking and synchronizing the active PDF page.
// --------------------------------------------------------------------------------------
import { useAtomValue, useSetAtom } from "jotai";
import {
  bookNavigationStateAtom,
  BookNavigationState,
  getCurrentViewParagraphsAtom,
  getNextViewParagraphsAtom,
  getPreviousViewParagraphsAtom,
  isTextGotAtom,
  pageNumberAtom,
  pageNumberToPageDataAtom,
  scrollPageNumberAtom,
  setPageNumberAtom,
} from "../atoms/paragraph-atoms";
import { useEffect } from "react";
import { getCurrrentPageNumber } from "../utils/getCurrentPageNumbers";
import { debounce } from "throttle-debounce";
// import { playerControl } from "@/models/pdf_player_control";
import type { Virtualizer } from "@tanstack/react-virtual";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "react-toastify";
import { pageDataToParagraphs } from "../utils/getPageParagraphs";
import { customStore } from "@/stores/jotai";
import isEqual from "fast-deep-equal";
import { eventBus, EventBusEvent } from "@/utils/bus";
import { Book } from "@/generated";
import { updateBookLocation } from "@/generated";

// --------------------------------------------------------------------------------------
// Returns and maintains the current page number for the active PDF view. The hook:
// - Seeds state from the persisted `book.location`.
// - Watches scroll/resize events to keep the jotai atom in sync.
// - Debounces writes so the backend location is updated sparingly.
// --------------------------------------------------------------------------------------
export function useCurrentPageNumber(
  scrollRef: React.RefObject<HTMLDivElement | null>,
  book: Book,
  virtualizer?: Virtualizer<HTMLDivElement, Element>
) {
  const currentPageNumber = useAtomValue(pageNumberAtom);
  const setScrollPageNumber = useSetAtom(scrollPageNumberAtom);
  const setPageNumber = useSetAtom(setPageNumberAtom);
  const bookId = book.id;

  // ------------------------------------------------------------------------------------
  // Dereference the scrolling container once so listeners can be registered cleanly.
  // ------------------------------------------------------------------------------------
  // const scrollDiv = scrollRef.current;
  // Set book data only when book prop changes, not on every render
  const setCurrentViewParagraphs = useSetAtom(getCurrentViewParagraphsAtom);
  const setIsTextGot = useSetAtom(isTextGotAtom);
  const setNextViewParagraphs = useSetAtom(getNextViewParagraphsAtom);
  const setPreviousViewParagraphs = useSetAtom(getPreviousViewParagraphsAtom);
  useEffect(() => {
    const interval = setInterval(() => {
      const visiblePageNumber = getCurrrentPageNumber(window);
      // Read current page number from atom (always up-to-date, even during async scroll)
      const atomPageNumber = customStore.get(pageNumberAtom);
      const navigationState = customStore.get(bookNavigationStateAtom);

      // If navigation is in progress and scroll has completed (visible matches atom),
      // reset navigation state to allow future navigation
      if (
        navigationState === BookNavigationState.Navigating &&
        visiblePageNumber === atomPageNumber
      ) {
        customStore.set(bookNavigationStateAtom, BookNavigationState.Navigated);
      }

      // Detect manual scrolling - update atom if user scrolled manually
      // BUT: Don't overwrite programmatic navigation that's in progress!
      if (
        visiblePageNumber !== atomPageNumber &&
        navigationState !== BookNavigationState.Navigating
      ) {
        setScrollPageNumber(visiblePageNumber);
      }

      // Use atomPageNumber (updated immediately on programmatic navigation)
      // instead of visiblePageNumber (which lags during async scroll)
      const pageNumberToPageData = customStore.get(pageNumberToPageDataAtom);
      const data = pageNumberToPageData[atomPageNumber];
      if (!data) return;

      const newCurrentViewParagraphs = pageDataToParagraphs(
        atomPageNumber,
        data
      );
      const nextPageData = pageNumberToPageData[atomPageNumber + 1];
      const newNextViewParagraphs = nextPageData
        ? pageDataToParagraphs(atomPageNumber + 1, nextPageData)
        : [];
      const previousPageData = pageNumberToPageData[atomPageNumber - 1];
      const newPreviousViewParagraphs = previousPageData
        ? pageDataToParagraphs(atomPageNumber - 1, previousPageData)
        : [];

      const currentViewParagraphs = customStore.get(
        getCurrentViewParagraphsAtom
      );
      const nextViewParagraphs = customStore.get(getNextViewParagraphsAtom);
      const previousViewParagraphs = customStore.get(
        getPreviousViewParagraphsAtom
      );

      if (!isEqual(currentViewParagraphs, newCurrentViewParagraphs)) {
        setCurrentViewParagraphs(newCurrentViewParagraphs);
        setIsTextGot(true);
        // Publish immediately when paragraphs are updated
        eventBus.publish(
          EventBusEvent.NEW_PARAGRAPHS_AVAILABLE,
          newCurrentViewParagraphs
        );
      }
      if (!isEqual(nextViewParagraphs, newNextViewParagraphs)) {
        setNextViewParagraphs(newNextViewParagraphs);
        eventBus.publish(
          EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE,
          newNextViewParagraphs
        );
      }
      if (!isEqual(previousViewParagraphs, newPreviousViewParagraphs)) {
        setPreviousViewParagraphs(newPreviousViewParagraphs);
        eventBus.publish(
          EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE,
          newPreviousViewParagraphs
        );
      }
    }, 500);
    return () => clearInterval(interval);
  }, []);
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

    onError(_error) {
      toast.error("Can not change book page");
    },
    onSuccess() {
      void queryClient.invalidateQueries({ queryKey: ["books"] });
      void queryClient.invalidateQueries({ queryKey: ["book", bookId] });
    },
  });

  // ------------------------------------------------------------------------------------
  // Scroll to the current page number
  // ------------------------------------------------------------------------------------
  useEffect(() => {
    if (!virtualizer) return;
    if (currentPageNumber === 0) return;
    const viewedPageNumber = getCurrrentPageNumber(window);
    if (viewedPageNumber === currentPageNumber) return;
  }, [currentPageNumber, virtualizer]);
  // ------------------------------------------------------------------------------------
  // Persist the latest page to the backend after the user settles on a location.
  // ------------------------------------------------------------------------------------
  useEffect(() => {
    const pageNumber = parseInt(book.location, 10);
    // virtualizer?.scrollToIndex(pageNumber - 1, { align: "start", behavior: "auto" })

    setPageNumber(pageNumber);
  }, []);

  useEffect(() => {
    // Debounce the backend update to avoid excessive writes during scrolling,
    // but allow a delay so that the current page number is innitialized properly.
    // using the saved book bumber
    setTimeout(() => {
      debounce(1000, () => {
        updateBookLocationMutation.mutate({
          bookId: bookId.toString(),
          location: currentPageNumber.toString(),
        });
      })();
    }, 1000);
  }, [currentPageNumber]);
  //
  return currentPageNumber;
}
export function findElementWithPageNumber(
  pageNumber: number,
  scrollContainerRef: HTMLDivElement
) {
  // ------------------------------------------------------------------------------------
  // Locate the DOM element tagged with the desired `data-page-number`.
  // ------------------------------------------------------------------------------------
  return scrollContainerRef.querySelector<HTMLElement>(
    `[data-page-number="${pageNumber}"]`
  );
}
