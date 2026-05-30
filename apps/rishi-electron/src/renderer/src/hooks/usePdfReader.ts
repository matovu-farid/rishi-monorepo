import { useEffect, useRef } from 'react'
import { createActor, fromPromise } from 'xstate'
import type { Virtualizer } from '@tanstack/react-virtual'
import type { TextContent } from 'react-pdf'
import isEqual from 'fast-deep-equal'
import { pdfReaderMachine } from '@/machines/pdfReaderMachine'
import { usePdfStore } from '@/stores/pdfStore'
import { usePlayerStore } from '@/stores/playerStore'
import { updateBookLocation } from '@/lib/api'
import { formatPdfLocation, parsePdfLocation } from '@/lib/pdfLocation'
import { debugLog } from '@/utils/debugLog'
import { pageDataToParagraphs } from '@/components/pdf/utils/getPageParagraphs'
import { pdfParagraphToPageNumber } from '@/components/pdf/utils/pdfParagraphToPageNumber'
import type { Book } from '@/lib/api'

/**
 * Returns `{ page, offset }` describing the page currently most-visible in
 * the virtualizer's viewport AND how many pixels have been scrolled past
 * the top of that page. Used both to detect page changes and to persist
 * sub-page scroll position so reopening lands at the same offset, not
 * snapped to the page boundary.
 */
// Hysteresis band (pixels) around a page boundary. While scrollTop sits
// within this band of the current page's edge, keep reporting the current
// page rather than flipping to the neighbour. Without this, slowly nudging
// the boundary back and forth across scrollTop fires PAGE_CHANGED on every
// wobble — and each PAGE_CHANGED cascades into pdfStore + view-actor +
// player updates that re-render the heavy pdf.tsx tree, dropping frames
// and reading as scroll jitter. 24px ≈ one CSS line of body text, small
// enough that the displayed page number never feels stale.
const PAGE_BOUNDARY_HYSTERESIS_PX = 24

function visiblePositionFromVirtualizer(
  virtualizer: Virtualizer<HTMLDivElement, Element>,
  container: HTMLElement | null,
  currentPage: number = 0
): { page: number; offset: number } {
  const items = virtualizer.getVirtualItems()
  if (items.length === 0) return { page: 0, offset: 0 }
  const scrollTop = container?.scrollTop ?? virtualizer.scrollOffset ?? 0

  // Pick the page whose [start, start+size) range contains the viewport's
  // top edge — i.e. the topmost visible page, matching the user's mental
  // model of "I'm reading at this scrollTop". The previous heuristic
  // (closest center to viewport center) collapsed sub-page offset to 0
  // whenever the viewport center happened to land in the next page's half.
  let topmost = items[0]
  for (const item of items) {
    if (item.start <= scrollTop && scrollTop < item.start + item.size) {
      topmost = item
      break
    }
    if (item.start <= scrollTop) topmost = item
  }
  const topmostPage = topmost.index + 1

  // Hysteresis: if we'd flip to a neighbour but scrollTop is still within
  // PAGE_BOUNDARY_HYSTERESIS_PX of the boundary, stick with currentPage.
  if (currentPage > 0 && topmostPage !== currentPage) {
    const currentItem = items.find((it) => it.index + 1 === currentPage)
    if (currentItem) {
      const distFromTop = Math.abs(scrollTop - currentItem.start)
      const distFromBottom = Math.abs(scrollTop - (currentItem.start + currentItem.size))
      if (distFromTop < PAGE_BOUNDARY_HYSTERESIS_PX || distFromBottom < PAGE_BOUNDARY_HYSTERESIS_PX) {
        return { page: currentPage, offset: Math.max(0, scrollTop - currentItem.start) }
      }
    }
  }

  return { page: topmostPage, offset: Math.max(0, scrollTop - topmost.start) }
}

export type UsePdfReaderApi = {
  sendDocLoaded: (numPages: number) => void
  seekTo: (page: number) => void
  flush: () => void
}

/**
 * Per-PdfView xstate actor that owns the reader's navigation + persistence
 * state. Replaces the old useCurrentPageNumber's tangle of useEffects, the
 * 500ms polling interval, and the BookNavigationState dance in pdfStore.
 *
 * One-way mirror of `currentPage` into `pdfStore.pageNumber` keeps existing
 * read-only consumers (pdf-page, thumbnail-sidebar, chat ChunkPager) working
 * without changes. Writes go exclusively through the machine.
 */
export function usePdfReader(
  book: Book,
  virtualizer: Virtualizer<HTMLDivElement, Element> | null,
  scrollContainerRef: React.RefObject<HTMLDivElement | null>
): UsePdfReaderApi {
  const apiRef = useRef<UsePdfReaderApi>({
    sendDocLoaded: () => {},
    seekTo: () => {},
    flush: () => {}
  })

  useEffect(() => {
    if (!virtualizer) return

    const { page: parsedPage, offset: parsedOffset } = parsePdfLocation(book.location)
    const resumePage = book.lastParagraph ? pdfParagraphToPageNumber(book.lastParagraph) : null
    const initialPage = resumePage ?? (parsedPage > 0 ? parsedPage : 1)
    const initialOffset = resumePage !== null ? 0 : parsedOffset
    const bookId = book.id

    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<
          { savedPage: number; savedOffset: number },
          { bookId: number; page: number; offset: number }
        >(async ({ input }) => {
          await updateBookLocation({
            bookId: input.bookId,
            newLocation: formatPdfLocation({ page: input.page, offset: input.offset })
          })
          return { savedPage: input.page, savedOffset: input.offset }
        })
      },
      actions: {
        // Fire-and-forget at unmount: no time to await an actor.
        flushSave: ({ context }) => {
          void updateBookLocation({
            bookId: context.bookId,
            newLocation: formatPdfLocation({
              page: context.currentPage,
              offset: context.currentOffset
            })
          })
        }
      }
    })

    const actor = createActor(machine, {
      input: { bookId, initialPage, initialOffset }
    })

    apiRef.current = {
      sendDocLoaded: (numPages) => actor.send({ type: 'DOC_LOADED', numPages }),
      seekTo: (page) => actor.send({ type: 'SEEK_REQUESTED', page }),
      flush: () => actor.send({ type: 'FLUSH' })
    }

    // --- Mirror machine.currentPage → pdfStore.pageNumber (back-compat).
    // Existing read-only consumers (pdf-page, thumbnails, chat) keep working
    // without modification.
    const mirrorUnsub = actor.subscribe((snap) => {
      const machinePage = snap.context.currentPage
      if (machinePage > 0 && usePdfStore.getState().pageNumber !== machinePage) {
        debugLog('pdfReader:mirrorPageNumber', {
          from: usePdfStore.getState().pageNumber,
          to: machinePage,
          isAutoCentering: usePdfStore.getState().isAutoCentering
        })
        usePdfStore.setState({ pageNumber: machinePage })
      }
    })

    // --- Drive virtualizer scroll when the machine enters seeking with a
    // new target. We don't use scrollToIndex(target-1, { align: 'start' })
    // because that lands at page-start exactly — losing the saved sub-page
    // offset. Instead we compute the absolute target (pageStart + pendingOffset)
    // from the virtualizer's measured offsets and call scrollToOffset.
    // pendingOffset is non-zero only on initial restore; user-initiated
    // SEEK_REQUESTED clears it so jump-to-page lands at page top.
    const driveSeek = (targetPage: number, offset: number): void => {
      const offsetInfo = virtualizer.getOffsetForIndex(targetPage - 1, 'start')
      if (!offsetInfo) {
        virtualizer.scrollToIndex(targetPage - 1, { align: 'start' })
        return
      }
      const [pageStart] = offsetInfo
      virtualizer.scrollToOffset(pageStart + offset, { align: 'start' })
    }
    let lastDrivenTarget: number | null = null
    const seekDriverUnsub = actor.subscribe((snap) => {
      const target = snap.context.seekTarget
      if (target !== null && target !== lastDrivenTarget) {
        lastDrivenTarget = target
        driveSeek(target, snap.context.pendingOffset)
      } else if (target === null) {
        lastDrivenTarget = null
      }
    })

    // --- Scroll listener: PAGE_CHANGED while in viewing.
    // Replaces the 500ms DOM-polling interval. Reads the visible page from
    // virtualizer geometry, so there's no "no canvas → return 1" sentinel.
    //
    // We attach to scrollContainerRef.current directly — `virtualizer.scrollElement`
    // is null until the virtualizer is enabled (numPages > 0), and our effect
    // runs before that, so capturing it eagerly silently produced a no-op
    // listener and the persist machine never received PAGE_CHANGED.
    const container = scrollContainerRef.current
    let scrollDebounce: ReturnType<typeof setTimeout> | null = null
    const seekRegion = (snap: ReturnType<typeof actor.getSnapshot>): string => {
      const v = snap.value
      return typeof v === 'object' && 'seek' in v
        ? String((v as Record<string, unknown>).seek)
        : String(v)
    }
    // Track scrollTop so the scroll handler can distinguish a real user scroll
    // from a layout-shift "scroll" event fired when the virtualizer applies
    // measurement adjustments — those don't change scrollTop, so the delta
    // check filters them out.
    let lastSeenScrollTop = container?.scrollTop ?? 0

    // DIAGNOSTIC (#scroll-jitter) — log raw scrollTop on every event so we
    // can spot non-monotonic movement during steady-direction user scroll
    // (a positive delta when scrolling UP = an adjustment fighting us).
    // Also captures scrollHeight + clientHeight so we can see if the
    // browser's scrollable area matches what TanStack thinks the total
    // size is — a mismatch would explain rubber-band bouncing partway
    // through what should be valid scroll range.
    // Sample at most once per 33ms so the log doesn't drown.
    let lastRawScrollLogAt = 0
    let lastRawScrollTop = container?.scrollTop ?? 0
    const handleRawScroll = (): void => {
      const now = Date.now()
      if (now - lastRawScrollLogAt < 33) return
      lastRawScrollLogAt = now
      const top = container?.scrollTop ?? 0
      const delta = top - lastRawScrollTop
      lastRawScrollTop = top
      const scrollHeight = container?.scrollHeight ?? 0
      const clientHeight = container?.clientHeight ?? 0
      const virt = usePdfStore.getState().virtualizer
      const tanstackTotal = virt ? virt.getTotalSize() : 0
      debugLog('scroll:raw', {
        scrollTop: top,
        delta,
        scrollHeight,
        clientHeight,
        maxScroll: scrollHeight - clientHeight,
        tanstackTotal,
        isAutoCentering: usePdfStore.getState().isAutoCentering
      })
    }
    container?.addEventListener('scroll', handleRawScroll, { passive: true })

    // Abort an in-flight seek the moment the user puts their finger on the
    // wheel/trackpad. driveSeek polls every 100ms to land the virtualizer
    // on the saved book position; if the user starts scrolling during that
    // window, each poll snaps scrollTop back to the seek target — felt as
    // strong resistance. wheel/touchstart are USER-INITIATED only (programmatic
    // scrolls don't fire them), so they're a clean signal that the user has
    // taken over and the seek should yield.
    const abortSeekOnUserInput = (): void => {
      if (seekRegion(actor.getSnapshot()) !== 'seeking') return
      debugLog('seek:aborted-by-user-input', {
        scrollTop: container?.scrollTop ?? 0,
        seekTarget: actor.getSnapshot().context.seekTarget
      })
      actor.send({ type: 'SEEK_LANDED' })
    }
    container?.addEventListener('wheel', abortSeekOnUserInput, { passive: true })
    container?.addEventListener('touchstart', abortSeekOnUserInput, { passive: true })

    const handleScroll = (): void => {
      if (scrollDebounce) clearTimeout(scrollDebounce)
      scrollDebounce = setTimeout(() => {
        if (seekRegion(actor.getSnapshot()) !== 'viewing') return
        // useScrolling runs a framer-motion animate to center the active
        // paragraph; that animate drives scrollTop programmatically and is
        // NOT a user-initiated page change. If we interpret it as one, we
        // get the #252 follow-up regression: centering paragraph 2 of page
        // N briefly scrolls into page N-1's range, this handler reports
        // visible page = N-1, PAGE_CHANGED(N-1) flows to pdfStore.pageNumber,
        // the view actor emits VIEW_CHANGED with page N-1's paragraphs, and
        // the player snaps to paragraph 0 of N-1.
        if (usePdfStore.getState().isAutoCentering) {
          debugLog('pdfReader:scrollSuppressed', { reason: 'auto-centering' })
          return
        }
        const currentScrollTop = container?.scrollTop ?? 0
        const delta = Math.abs(currentScrollTop - lastSeenScrollTop)
        lastSeenScrollTop = currentScrollTop
        if (delta < 4) return
        const currentPage = actor.getSnapshot().context.currentPage
        const { page, offset } = visiblePositionFromVirtualizer(
          virtualizer,
          container,
          currentPage
        )
        if (!page) return
        debugLog('pdfReader:pageChanged', {
          page,
          offset,
          delta,
          isAutoCentering: usePdfStore.getState().isAutoCentering
        })
        actor.send({ type: 'PAGE_CHANGED', page, offset })
      }, 80)
    }
    container?.addEventListener('scroll', handleScroll, { passive: true })

    // Reset scrollTop baseline when we transition seeking → viewing, so the
    // first post-landing scroll event isn't compared against a stale baseline
    // (which would treat it as a huge user scroll instead of a layout shift).
    let prevRegion = seekRegion(actor.getSnapshot())
    const baselineUnsub = actor.subscribe((snap) => {
      const region = seekRegion(snap)
      if (region === 'viewing' && prevRegion !== 'viewing') {
        lastSeenScrollTop = container?.scrollTop ?? 0
      }
      prevRegion = region
    })

    // --- Seek-landed detection. While the machine is in `seeking`, poll
    // every 100ms; when the topmost visible page matches the target, send
    // SEEK_LANDED. Re-drives the seek (via driveSeek, which uses measured
    // page offsets + pendingOffset) on each tick where visible !== target —
    // the virtualizer's first scroll uses estimated page heights, and once
    // the actual pages render and get measured, the layout shifts. Without
    // re-driving, the user would land on a drifted page (or at page-start
    // with no sub-page offset applied) and that wrong position would get
    // saved.
    let landedInterval: ReturnType<typeof setInterval> | null = null
    let landedTicks = 0
    const landedUnsub = actor.subscribe((snap) => {
      const isSeeking = seekRegion(snap) === 'seeking'
      if (isSeeking && !landedInterval) {
        landedTicks = 0
        landedInterval = setInterval(() => {
          const ctx = actor.getSnapshot().context
          const target = ctx.seekTarget
          if (target === null) return
          const { page: visible } = visiblePositionFromVirtualizer(virtualizer, container)
          landedTicks++
          if (visible === target) {
            actor.send({ type: 'SEEK_LANDED' })
            return
          }
          if (landedTicks <= 30) {
            driveSeek(target, ctx.pendingOffset)
          } else {
            // Give up after ~3s; accept whatever's visible so we don't hang.
            actor.send({ type: 'SEEK_LANDED' })
          }
        }, 100)
      } else if (!isSeeking && landedInterval) {
        clearInterval(landedInterval)
        landedInterval = null
        landedTicks = 0
      }
    })

    // --- Paragraph publishing for player/TTS. When the machine's currentPage
    // changes (and we have rendered text for that page), recompute paragraphs
    // and publish to playerStore. No polling.
    let lastPublishedPage = -1
    const paragraphUnsub = actor.subscribe((snap) => {
      const page = snap.context.currentPage
      if (page === lastPublishedPage) return
      const pageDataMap = usePdfStore.getState().pageNumberToPageData
      const data = pageDataMap[page] as TextContent | undefined
      if (!data) return // page text not rendered yet; pdf-page will trigger re-eval
      lastPublishedPage = page
      publishParagraphsForPage(page, pageDataMap)
    })

    // Also re-publish when pdf-page mounts a NEW page's text (the machine page
    // may have already settled but data wasn't there at the time).
    const pageDataUnsub = usePdfStore.subscribe(
      (s) => s.pageNumberToPageData,
      (pageDataMap) => {
        const page = actor.getSnapshot().context.currentPage
        if (!(pageDataMap[page] as TextContent | undefined)) return
        publishParagraphsForPage(page, pageDataMap)
      }
    )

    // --- Re-publish paragraphs when the footer mask for THIS book arrives.
    // The eager footer-mask scan runs asynchronously after open — typically
    // 1–3s later. The two subscriptions above only fire on paragraph /
    // page-data changes, so without this hook the player keeps reading the
    // first page's footer chrome until the next page change shakes the
    // pipeline. Re-fire `publishParagraphsForPage` for the current page
    // when the mask reference for this book actually CHANGES (the selector
    // uses reference equality — `setFooterMask` always allocates a new
    // outer object so we won't loop on no-op updates).
    const footerMaskUnsub = usePdfStore.subscribe(
      (s) => s.footerMaskByBookId[bookId],
      (mask, prevMask) => {
        if (mask === prevMask) return
        const page = actor.getSnapshot().context.currentPage
        const pageDataMap = usePdfStore.getState().pageNumberToPageData
        if (!(pageDataMap[page] as TextContent | undefined)) return
        // Reset our "last published" guard so the upcoming re-publish
        // isn't suppressed — we WANT it to overwrite the (now stale,
        // chrome-included) paragraphs that were published before the
        // mask arrived.
        lastPublishedPage = -1
        publishParagraphsForPage(page, pageDataMap)
      }
    )

    actor.start()

    return () => {
      // Send FLUSH first so the machine fires the fire-and-forget IPC for any
      // unsaved page change before we tear down the actor.
      actor.send({ type: 'FLUSH' })
      actor.stop()
      container?.removeEventListener('scroll', handleScroll)
      container?.removeEventListener('scroll', handleRawScroll)
      container?.removeEventListener('wheel', abortSeekOnUserInput)
      container?.removeEventListener('touchstart', abortSeekOnUserInput)
      if (scrollDebounce) clearTimeout(scrollDebounce)
      if (landedInterval) clearInterval(landedInterval)
      mirrorUnsub.unsubscribe()
      seekDriverUnsub.unsubscribe()
      landedUnsub.unsubscribe()
      baselineUnsub.unsubscribe()
      paragraphUnsub.unsubscribe()
      pageDataUnsub()
      footerMaskUnsub()
      apiRef.current = {
        sendDocLoaded: () => {},
        seekTo: () => {},
        flush: () => {}
      }
    }
    // Why: book.location is only the initial seed for the xstate actor (parsed once on mount); the machine then owns location internally. Re-running the effect on every location persist would tear down/recreate the actor and lose state. scrollContainerRef is a stable ref object.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.id, virtualizer])

  // Why: apiRef.current holds the stable imperative handle to the xstate actor created in useEffect. Callers (PdfView) need synchronous access via the returned object. The ref's identity is stable across renders — only its current.* method bodies are swapped on effect re-run.
  // eslint-disable-next-line react-hooks/refs
  return apiRef.current
}

// Exported for the issue-#30 snap-back test (useScrolling.test.tsx) so the
// flag-lifecycle contract can be exercised end-to-end at the unit-test
// level. Production consumers stay inside usePdfReader's effect.
export function publishParagraphsForPage(
  page: number,
  pageDataMap: Record<number, TextContent>
): void {
  const data = pageDataMap[page] as TextContent | undefined
  if (!data) return
  const bookId = usePdfStore.getState().book?.id
  const maskFor = (p: number): ReadonlySet<number> | undefined =>
    bookId != null ? usePdfStore.getState().getFooterMaskForPage(bookId, p) : undefined
  const newCurrent = pageDataToParagraphs(page, data, maskFor(page))
  const nextData = pageDataMap[page + 1] as TextContent | undefined
  const newNext = nextData ? pageDataToParagraphs(page + 1, nextData, maskFor(page + 1)) : []
  const prevData = pageDataMap[page - 1] as TextContent | undefined
  const newPrev = prevData ? pageDataToParagraphs(page - 1, prevData, maskFor(page - 1)) : []

  const pdfState = usePdfStore.getState()
  const currentDiffers = !isEqual(pdfState.currentViewParagraphs, newCurrent)
  if (currentDiffers) {
    pdfState.setCurrentViewParagraphs(newCurrent)
    pdfState.setIsTextGot(true)
    usePlayerStore.getState().setCurrentParagraphs(newCurrent)
  }
  if (!isEqual(pdfState.nextViewParagraphs, newNext)) {
    pdfState.setNextViewParagraphs(newNext)
    usePlayerStore.getState().setNextPageParagraphs(newNext)
  }
  if (!isEqual(pdfState.previousViewParagraphs, newPrev)) {
    pdfState.setPreviousViewParagraphs(newPrev)
    usePlayerStore.getState().setPrevPageParagraphs(newPrev)
  }

  // NOTE on the page-advance suppression flag (issue #30 refined symptom):
  // We used to clear `isLookingForNextParagraph` here once `currentDiffers`
  // flipped — i.e. as soon as the new page's paragraphs landed. That
  // happens BEFORE the player resolves audio for the new page and assigns
  // a fresh `highlightedParagraphIndex`. The window between this point
  // and the highlight-assignment was a no-op for `useScrolling` (no
  // highlighted paragraph matched the new view), so the suppression was
  // already gone by the time the effect actually ran for the first
  // new-page highlight. That highlight sat flush with the top of the
  // viewport (virtualizer scrolled with `align:'start'`), and useScrolling's
  // centering math scrolled *back* toward the previous page to center it —
  // exactly the "advances, then snaps back" symptom on PR #31.
  //
  // The flag is now spent inside `useScrolling`'s timeout body, at the
  // point where it would otherwise issue the centering scroll. That's
  // the rendezvous where we KNOW the new page is rendered, the highlight
  // is resolved, and the suppression has done its job.
}
