// --------------------------------------------------------------------------------------
// Hook utilities and helpers for tracking and synchronizing the active PDF page.
// --------------------------------------------------------------------------------------
import { usePdfStore, BookNavigationState } from '@/stores/pdfStore'
import { useEffect, useRef } from 'react'
import { getCurrrentPageNumber } from '../utils/getCurrentPageNumbers'
import type { Virtualizer } from '@tanstack/react-virtual'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { pageDataToParagraphs } from '../utils/getPageParagraphs'
import isEqual from 'fast-deep-equal'
import { usePlayerStore } from '@/stores/playerStore'
import type { Book } from '@/lib/api'
import { updateBookLocation } from '@/lib/api'

// --------------------------------------------------------------------------------------
// Returns and maintains the current page number for the active PDF view. The hook:
// - Seeds state from the persisted `book.location`.
// - Watches scroll/resize events to keep the store in sync.
// - Debounces writes so the backend location is updated sparingly.
// --------------------------------------------------------------------------------------
export function useCurrentPageNumber(
  _scrollRef: React.RefObject<HTMLDivElement | null>,
  book: Book,
  virtualizer?: Virtualizer<HTMLDivElement, Element>
) {
  const currentPageNumber = usePdfStore((s) => s.pageNumber)
  const setScrollPageNumber = usePdfStore((s) => s.setScrollPageNumber)
  const setPageNumber = usePdfStore((s) => s.setPageNumber)
  const navState = usePdfStore((s) => s.bookNavigationState)
  const bookId = book.id
  const lastSavedRef = useRef<number | null>(parseInt(book.location, 10) || null)
  const pendingSaveRef = useRef<number | null>(null)

  // ------------------------------------------------------------------------------------
  // Dereference the scrolling container once so listeners can be registered cleanly.
  // ------------------------------------------------------------------------------------
  // Set book data only when book prop changes, not on every render
  const setCurrentViewParagraphs = usePdfStore((s) => s.setCurrentViewParagraphs)
  const setIsTextGot = usePdfStore((s) => s.setIsTextGot)
  const setNextViewParagraphs = usePdfStore((s) => s.setNextViewParagraphs)
  const setPreviousViewParagraphs = usePdfStore((s) => s.setPreviousViewParagraphs)
  useEffect(() => {
    const interval = setInterval(() => {
      const visiblePageNumber = getCurrrentPageNumber(window)
      // Read current page number from store (always up-to-date, even during async scroll)
      const state = usePdfStore.getState()
      const atomPageNumber = state.pageNumber
      const navigationState = state.bookNavigationState

      // If navigation is in progress and scroll has completed (visible matches store),
      // reset navigation state to allow future navigation
      if (
        navigationState === BookNavigationState.Navigating &&
        visiblePageNumber === atomPageNumber
      ) {
        usePdfStore.getState().setBookNavigationState(BookNavigationState.Navigated)
      }

      // Detect manual scrolling - update store if user scrolled manually
      // BUT: Don't overwrite programmatic navigation that's in progress!
      if (
        visiblePageNumber !== atomPageNumber &&
        navigationState !== BookNavigationState.Navigating
      ) {
        setScrollPageNumber(visiblePageNumber)
      }

      // Use atomPageNumber (updated immediately on programmatic navigation)
      // instead of visiblePageNumber (which lags during async scroll)
      const pageNumberToPageData = usePdfStore.getState().pageNumberToPageData
      const data = pageNumberToPageData[atomPageNumber]
      if (!data) return

      const newCurrentViewParagraphs = pageDataToParagraphs(atomPageNumber, data)
      const nextPageData = pageNumberToPageData[atomPageNumber + 1]
      const newNextViewParagraphs = nextPageData
        ? pageDataToParagraphs(atomPageNumber + 1, nextPageData)
        : []
      const previousPageData = pageNumberToPageData[atomPageNumber - 1]
      const newPreviousViewParagraphs = previousPageData
        ? pageDataToParagraphs(atomPageNumber - 1, previousPageData)
        : []

      const currentViewParagraphs = usePdfStore.getState().currentViewParagraphs
      const nextViewParagraphs = usePdfStore.getState().nextViewParagraphs
      const previousViewParagraphs = usePdfStore.getState().previousViewParagraphs

      if (!isEqual(currentViewParagraphs, newCurrentViewParagraphs)) {
        setCurrentViewParagraphs(newCurrentViewParagraphs)
        setIsTextGot(true)
        // Publish immediately when paragraphs are updated
        usePlayerStore.getState().setCurrentParagraphs(newCurrentViewParagraphs)
      }
      if (!isEqual(nextViewParagraphs, newNextViewParagraphs)) {
        setNextViewParagraphs(newNextViewParagraphs)
        usePlayerStore.getState().setNextPageParagraphs(newNextViewParagraphs)
      }
      if (!isEqual(previousViewParagraphs, newPreviousViewParagraphs)) {
        setPreviousViewParagraphs(newPreviousViewParagraphs)
        usePlayerStore.getState().setPrevPageParagraphs(newPreviousViewParagraphs)
      }
    }, 500)
    return () => clearInterval(interval)
  }, [])
  const queryClient = useQueryClient()
  const updateBookLocationMutation = useMutation({
    mutationFn: async ({ bookId, location }: { bookId: string; location: string }) => {
      await updateBookLocation({
        bookId: Number(bookId),
        newLocation: location
      })
    },

    onError(_error) {
      toast.error('Can not change book page')
    },
    onSuccess() {
      void queryClient.invalidateQueries({ queryKey: ['books'] })
      void queryClient.invalidateQueries({ queryKey: ['book', bookId] })
    }
  })

  // ------------------------------------------------------------------------------------
  // Scroll to the current page number
  // ------------------------------------------------------------------------------------
  useEffect(() => {
    if (!virtualizer) return
    if (currentPageNumber === 0) return
    const viewedPageNumber = getCurrrentPageNumber(window)
    if (viewedPageNumber === currentPageNumber) return
  }, [currentPageNumber, virtualizer])
  // ------------------------------------------------------------------------------------
  // Persist the latest page to the backend after the user settles on a location.
  // ------------------------------------------------------------------------------------
  useEffect(() => {
    const pageNumber = parseInt(book.location, 10)

    setPageNumber(pageNumber)
  }, [])

  useEffect(() => {
    // Only persist after the initial seek has landed; otherwise the broken
    // canvas-default-of-1 in `getCurrrentPageNumber` would clobber the saved
    // location with "1".
    if (navState !== BookNavigationState.Navigated) return
    if (!currentPageNumber || isNaN(currentPageNumber)) return
    if (currentPageNumber === lastSavedRef.current) return

    pendingSaveRef.current = currentPageNumber
    const target = currentPageNumber
    const handle = setTimeout(() => {
      updateBookLocationMutation.mutate({
        bookId: bookId.toString(),
        location: String(target)
      })
      lastSavedRef.current = target
      pendingSaveRef.current = null
    }, 400)

    return () => clearTimeout(handle)
  }, [currentPageNumber, navState])

  // Flush the latest visible page on unmount. Polling only ticks every 500ms,
  // so closing within that window leaves `pendingSaveRef` empty — sample the
  // DOM directly to catch the user's actual last position.
  useEffect(() => {
    return () => {
      let target: number | null = null
      try {
        const hasCanvases =
          document.querySelectorAll('[data-page-number]:has(> canvas)').length > 0
        if (hasCanvases) {
          // Trust the DOM only when canvases exist; otherwise the function
          // returns `1` as a sentinel and would clobber a real saved page.
          const fromDom = getCurrrentPageNumber(window)
          if (fromDom > 0) target = fromDom
        }
      } catch {
        // Non-DOM env (tests) — fall through.
      }
      if (target === null) target = pendingSaveRef.current
      if (target === null) {
        const fromStore = usePdfStore.getState().pageNumber
        if (fromStore && fromStore > 0 && !isNaN(fromStore)) target = fromStore
      }
      if (target !== null && target !== lastSavedRef.current && target > 0 && !isNaN(target)) {
        void updateBookLocation({ bookId: Number(bookId), newLocation: String(target) })
      }
    }
  }, [bookId])
  //
  return currentPageNumber
}
export function findElementWithPageNumber(pageNumber: number, scrollContainerRef: HTMLDivElement) {
  // ------------------------------------------------------------------------------------
  // Locate the DOM element tagged with the desired `data-page-number`.
  // ------------------------------------------------------------------------------------
  return scrollContainerRef.querySelector<HTMLElement>(`[data-page-number="${pageNumber}"]`)
}
