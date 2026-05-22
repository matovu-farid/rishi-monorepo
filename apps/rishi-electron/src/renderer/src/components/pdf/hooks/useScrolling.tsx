import { useEffect, useRef } from 'react'
import { animate } from 'framer-motion'
import { usePlayerStore } from '@/stores/playerStore'

import { usePdfStore } from '@/stores/pdfStore'

export function useScrolling(scrollContainerRef: React.RefObject<HTMLDivElement | null>) {
  const highlightedParagraphIndex = usePdfStore((s) => s.highlightedParagraphIndex)
  const currentViewParagraphs = usePdfStore((s) => s.currentViewParagraphs)
  const highlightedParagraph = currentViewParagraphs.find(
    (p) => p.index === highlightedParagraphIndex
  )
  const isRendered = usePdfStore((s) => s.isTextGot)

  // Track whether we paused the player due to user scroll
  const pausedByScrollRef = useRef(false)
  const scrollDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Detect user-initiated scroll (wheel/touch) and pause/resume player.
  // We listen for wheel/touchmove rather than the generic "scroll" event so
  // that programmatic scrollTop changes (from our own animate() or the
  // virtualizer) don't accidentally pause the player.
  useEffect(() => {
    const container = scrollContainerRef.current
    if (!container) return

    const handleUserScroll = () => {
      const { playingState, send } = usePlayerStore.getState()

      if (playingState === 'playing' && !pausedByScrollRef.current) {
        send?.({ type: 'PAUSE' })
        pausedByScrollRef.current = true
      }

      // Reset the debounce timer on every scroll event
      if (scrollDebounceRef.current) {
        clearTimeout(scrollDebounceRef.current)
      }

      // Once scrolling settles, resume the player
      scrollDebounceRef.current = setTimeout(() => {
        if (pausedByScrollRef.current) {
          pausedByScrollRef.current = false
          usePlayerStore.getState().send?.({ type: 'RESUME' })
        }
      }, 300)
    }

    container.addEventListener('wheel', handleUserScroll, { passive: true })
    container.addEventListener('touchmove', handleUserScroll, { passive: true })

    return () => {
      container.removeEventListener('wheel', handleUserScroll)
      container.removeEventListener('touchmove', handleUserScroll)
      if (scrollDebounceRef.current) {
        clearTimeout(scrollDebounceRef.current)
      }
      // If we paused the player and the component unmounts, resume it
      if (pausedByScrollRef.current) {
        pausedByScrollRef.current = false
        usePlayerStore.getState().send?.({ type: 'RESUME' })
      }
    }
  }, [scrollContainerRef])

  // Auto-scroll to the highlighted paragraph
  useEffect(() => {
    const container = scrollContainerRef.current
    if (!container || !highlightedParagraph?.index) return

    // Gate until that page's text layer has been rendered
    if (!isRendered) return

    const timeout = setTimeout(() => {
      // Don't auto-scroll while the user is actively scrolling
      if (pausedByScrollRef.current) return

      const el = [...container.querySelectorAll<HTMLElement>('mark')].find((mark) => mark.innerText)
      if (!el) return
      // Page-advance suppression (issue #30 refined symptom): when
      // `pageControls.nextPage`/`previousPage` set this flag, the
      // virtualizer has just scrolled the new page flush with the top
      // of the viewport via `align: 'start'` (or `'end'`). The first
      // highlight that lands on the new page (paragraph 0 / last) sits
      // right at that viewport edge — the centering math below would
      // scroll *back* toward the previous page to put it in the middle,
      // producing the "advances, then snaps back" behaviour the user
      // reported on PR #31. Spend the suppression here: clear the flag
      // and skip the centering scroll for this single tick. Subsequent
      // in-page paragraph advances will see flag=false and auto-center
      // as usual.
      //
      // Why not clear the flag in `publishParagraphsForPage` (where it
      // used to live)? Because paragraphs publish BEFORE the player
      // resolves the new page's audio and assigns
      // `highlightedParagraphIndex` — a window where this effect was
      // idle (no highlighted paragraph matched the new view). By the
      // time the effect actually fires, the flag has already been
      // cleared upstream and the suppression is wasted. Clearing here
      // is the rendezvous: we know the new page is rendered, the
      // highlight is resolved, and the next effect run will be a
      // genuine in-page advance.
      const isLookingForNextParagraph = usePdfStore.getState().isLookingForNextParagraph
      if (isLookingForNextParagraph) {
        usePdfStore.getState().setIsLookingForNextParagraph(false)
        return
      }

      // Calculate the target scroll position
      const containerRect = container.getBoundingClientRect()
      const elementRect = el.getBoundingClientRect()

      // Current scroll position + element's position relative to container
      const currentScrollTop = container.scrollTop
      const elementTopRelativeToContainer = elementRect.top - containerRect.top + currentScrollTop

      // Calculate target scroll position to center the element
      const targetScrollTop =
        elementTopRelativeToContainer - container.clientHeight / 2 + elementRect.height / 2

      // Use framer-motion's animate for smooth scrolling
      animate(container.scrollTop, targetScrollTop, {
        duration: 0.8,
        ease: [0.4, 0, 0.2, 1], // Custom easing curve for smoother feel
        onUpdate: (latest) => {
          container.scrollTop = latest
        }
      })
    }, 100)
    return () => clearTimeout(timeout)
  }, [highlightedParagraph, isRendered, scrollContainerRef])
}
