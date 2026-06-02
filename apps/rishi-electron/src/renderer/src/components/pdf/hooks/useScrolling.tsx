import { useEffect, useRef } from 'react'
import { animate, type AnimationPlaybackControls } from 'framer-motion'
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

  // Track the most recent framer-motion `animate(...)` controls so we can
  // call `.stop()` on it when a page advance happens — otherwise the previous
  // page's centering animate keeps overwriting `container.scrollTop` on every
  // rAF tick, fighting the virtualizer's scroll to the new page and
  // producing the user-visible "advances then snaps back" symptom of #30.
  const activeAnimateRef = useRef<AnimationPlaybackControls | null>(null)
  // Trailing timer that clears `pdfStore.isAutoCentering` AFTER the animate
  // completes. Why a delay: usePdfReader.handleScroll debounces scroll events
  // by 80 ms; the last onUpdate scroll event fires at ~animate.end, and
  // `onComplete` clears the flag synchronously on the same tick. If we cleared
  // immediately, the 80 ms debounce would expire AFTER the flag was already
  // false, handleScroll would proceed, and pdfReaderMachine would receive
  // PAGE_CHANGED based on the centered scrollTop — flipping pdfStore.pageNumber
  // back to the previous page when the centered paragraph sits near the top
  // of the current page (#252 follow-up regression). 200 ms covers the
  // debounce + a comfortable buffer; new animates clear and re-set the timer.
  const clearAutoCenterTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const scheduleAutoCenterClear = (): void => {
    if (clearAutoCenterTimerRef.current) clearTimeout(clearAutoCenterTimerRef.current)
    clearAutoCenterTimerRef.current = setTimeout(() => {
      clearAutoCenterTimerRef.current = null
      usePdfStore.getState().setIsAutoCentering(false)
    }, 200)
  }
  const cancelPendingAutoCenterClear = (): void => {
    if (clearAutoCenterTimerRef.current) {
      clearTimeout(clearAutoCenterTimerRef.current)
      clearAutoCenterTimerRef.current = null
    }
  }

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

  // Primary defence against the #30 snap-back: the moment
  // `pageControls.nextPage`/`previousPage` flips the suppression flag,
  // cancel any in-flight centering animate. Otherwise an 800 ms tween
  // captured for the page-N target keeps writing scrollTop on every rAF
  // tick after the virtualizer has already moved to page N+1, pulling
  // the reader back. The flag-read-and-clear inside the centering effect
  // below is a secondary guard for the edge case where no animate is in
  // flight at the boundary — without it the first new-page highlight
  // would still re-center into the previous page by one frame's worth.
  useEffect(() => {
    const unsub = usePdfStore.subscribe(
      (s) => s.isLookingForNextParagraph,
      (flag) => {
        if (flag && activeAnimateRef.current) {
          activeAnimateRef.current.stop()
          activeAnimateRef.current = null
          // Schedule the delayed clear so any trailing scroll-debounce in
          // usePdfReader.handleScroll still sees the suppression flag.
          if (usePdfStore.getState().isAutoCentering) {
            scheduleAutoCenterClear()
          }
        }
      }
    )
    return unsub
  }, [])

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
      let targetScrollTop =
        elementTopRelativeToContainer - container.clientHeight / 2 + elementRect.height / 2

      // Centering clamp (issue: jarring back-shift on paragraph 1 of a
      // freshly-snapped page). After `pageControls.nextPage()` aligns the
      // new page flush with the viewport top via `align:'start'`, paragraph
      // 0 is suppressed by `isLookingForNextParagraph` above — but paragraph
      // 1 (and any other paragraph in the top half of the viewport) would
      // otherwise be centered, which pulls `scrollTop` *below* the page's
      // top in document coordinates and visually drags the prior page's
      // bottom back into view. Clamp the target to the top of the page that
      // owns the highlighted mark; never scroll backward past it.
      const pageEl = el.closest<HTMLElement>('[data-page-number]')
      if (pageEl) {
        const pageRect = pageEl.getBoundingClientRect()
        const pageTopInDoc = pageRect.top - containerRect.top + currentScrollTop
        if (targetScrollTop < pageTopInDoc) {
          targetScrollTop = pageTopInDoc
        }
      }

      // After clamping, if the target equals the current position, skip the
      // animate entirely — otherwise framer-motion spins a 0.8 s no-op tween
      // and we needlessly hold `isAutoCentering` true through the trailing
      // 200 ms clear, blocking usePdfReader's scroll-debounce for ~1 s.
      if (Math.abs(targetScrollTop - currentScrollTop) < 1) {
        return
      }

      // Stop any in-flight animate before starting a new one. framer-motion's
      // `animate(value, value, opts)` returns controls but does NOT cancel
      // previous calls — running two animates simultaneously means both
      // write to `container.scrollTop` on every rAF tick and they fight,
      // producing the snap-back symptom of #30 when a page advance
      // happens mid-animate.
      activeAnimateRef.current?.stop()

      // Signal to usePdfReader.handleScroll that the upcoming scroll events
      // are programmatic centering, not user navigation. A new animate also
      // cancels any pending trailing-clear from a previous animate so the
      // flag stays continuously true across rapid paragraph advances.
      cancelPendingAutoCenterClear()
      usePdfStore.getState().setIsAutoCentering(true)

      // Use framer-motion's animate for smooth scrolling
      activeAnimateRef.current = animate(container.scrollTop, targetScrollTop, {
        duration: 0.8,
        ease: [0.4, 0, 0.2, 1], // Custom easing curve for smoother feel
        onUpdate: (latest) => {
          container.scrollTop = latest
        },
        onComplete: () => {
          // Self-clear so the next effect run doesn't `.stop()` a finished
          // animation (no-op, but keeps the ref honest). The flag itself
          // is cleared trailingly so the post-animate scroll debounce in
          // usePdfReader still sees suppression.
          activeAnimateRef.current = null
          scheduleAutoCenterClear()
        }
      })
    }, 100)
    return () => {
      clearTimeout(timeout)
      // Cancel any in-flight animate so a stale centering scroll cannot
      // overwrite scrollTop after this effect's highlight has changed.
      activeAnimateRef.current?.stop()
      activeAnimateRef.current = null
      // Schedule the trailing clear (don't clear immediately) — a scroll
      // event from the now-stopped animate may still be in handleScroll's
      // 80 ms debounce queue, and clearing the flag now would let it
      // through. If the cleanup is for an unmount, the deferred timer is
      // harmless (the store flag is renderer-global).
      if (usePdfStore.getState().isAutoCentering) {
        scheduleAutoCenterClear()
      }
    }
  }, [highlightedParagraph, isRendered, scrollContainerRef])
}
