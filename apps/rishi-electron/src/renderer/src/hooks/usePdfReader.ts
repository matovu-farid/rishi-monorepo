import { useEffect, useRef } from 'react'
import { createActor, fromPromise } from 'xstate'
import type { Virtualizer } from '@tanstack/react-virtual'
import isEqual from 'fast-deep-equal'
import { pdfReaderMachine } from '@/machines/pdfReaderMachine'
import { usePdfStore } from '@/stores/pdfStore'
import { usePlayerStore } from '@/stores/playerStore'
import { updateBookLocation } from '@/lib/api'
import { pageDataToParagraphs } from '@/components/pdf/utils/getPageParagraphs'
import type { Book } from '@/lib/api'

/**
 * Returns the page index (1-based) currently most-visible in the virtualizer's
 * viewport, or 0 if the virtualizer has no items rendered yet. Uses the
 * container's actual scrollTop (authoritative) and virtualizer item geometry.
 * No DOM queries, no canvas sentinels.
 */
function visiblePageFromVirtualizer(
  virtualizer: Virtualizer<HTMLDivElement, Element>,
  container: HTMLElement | null
): number {
  const items = virtualizer.getVirtualItems()
  if (items.length === 0) return 0
  const scrollTop = container?.scrollTop ?? virtualizer.scrollOffset ?? 0
  const viewportSize = container?.clientHeight ?? 0
  const center = scrollTop + viewportSize / 2

  let closest = items[0]
  let closestDist = Math.abs(closest.start + closest.size / 2 - center)
  for (let i = 1; i < items.length; i++) {
    const item = items[i]
    const dist = Math.abs(item.start + item.size / 2 - center)
    if (dist < closestDist) {
      closestDist = dist
      closest = item
    }
  }
  return closest.index + 1
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

    const initialPage = parseInt(book.location, 10) || 1
    const bookId = book.id

    const machine = pdfReaderMachine.provide({
      actors: {
        saveLocation: fromPromise<
          { savedPage: number },
          { bookId: number; page: number }
        >(async ({ input }) => {
          await updateBookLocation({
            bookId: input.bookId,
            newLocation: String(input.page)
          })
          return { savedPage: input.page }
        })
      },
      actions: {
        // Fire-and-forget at unmount: no time to await an actor.
        flushSave: ({ context }) => {
          void updateBookLocation({
            bookId: context.bookId,
            newLocation: String(context.currentPage)
          })
        }
      }
    })

    const actor = createActor(machine, { input: { bookId, initialPage } })

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
        usePdfStore.setState({ pageNumber: machinePage })
      }
    })

    // --- Drive virtualizer.scrollToIndex when the machine enters seeking
    // with a new target. The user (or initial-restore) requests a seek;
    // the virtualizer animates; the scroll listener / landed-poll detects
    // arrival and sends SEEK_LANDED.
    let lastDrivenTarget: number | null = null
    const seekDriverUnsub = actor.subscribe((snap) => {
      const target = snap.context.seekTarget
      if (target !== null && target !== lastDrivenTarget) {
        lastDrivenTarget = target
        virtualizer.scrollToIndex(target - 1, { align: 'start' })
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
      return typeof v === 'object' && v !== null && 'seek' in v
        ? String((v as Record<string, unknown>).seek)
        : String(v)
    }
    // Track scrollTop so the scroll handler can distinguish a real user scroll
    // from a layout-shift "scroll" event fired when the virtualizer applies
    // measurement adjustments — those don't change scrollTop, so the delta
    // check filters them out.
    let lastSeenScrollTop = container?.scrollTop ?? 0
    const handleScroll = (): void => {
      if (scrollDebounce) clearTimeout(scrollDebounce)
      scrollDebounce = setTimeout(() => {
        if (seekRegion(actor.getSnapshot()) !== 'viewing') return
        const currentScrollTop = container?.scrollTop ?? 0
        const delta = Math.abs(currentScrollTop - lastSeenScrollTop)
        lastSeenScrollTop = currentScrollTop
        if (delta < 4) return
        const visible = visiblePageFromVirtualizer(virtualizer, container)
        if (!visible) return
        actor.send({ type: 'PAGE_CHANGED', page: visible })
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

    // --- Seek-landed detection. While the machine is in `seeking`, poll the
    // visible page every 100ms; when it matches the target, send SEEK_LANDED.
    // Re-issues scrollToIndex on each tick where visible !== target — the
    // virtualizer's first scroll uses estimated page heights, and once the
    // actual pages render and get measured, the layout shifts. Without
    // re-scrolling, the user would land on a drifted page and that wrong page
    // would get saved.
    let landedInterval: ReturnType<typeof setInterval> | null = null
    let landedTicks = 0
    const landedUnsub = actor.subscribe((snap) => {
      const isSeeking = seekRegion(snap) === 'seeking'
      if (isSeeking && !landedInterval) {
        landedTicks = 0
        landedInterval = setInterval(() => {
          const target = actor.getSnapshot().context.seekTarget
          if (target === null) return
          const visible = visiblePageFromVirtualizer(virtualizer, container)
          landedTicks++
          if (visible === target) {
            actor.send({ type: 'SEEK_LANDED' })
            return
          }
          if (landedTicks <= 30) {
            virtualizer.scrollToIndex(target - 1, { align: 'start' })
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
      const data = pageDataMap[page]
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
        if (!pageDataMap[page]) return
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
      if (scrollDebounce) clearTimeout(scrollDebounce)
      if (landedInterval) clearInterval(landedInterval)
      mirrorUnsub.unsubscribe()
      seekDriverUnsub.unsubscribe()
      landedUnsub.unsubscribe()
      baselineUnsub.unsubscribe()
      paragraphUnsub.unsubscribe()
      pageDataUnsub()
      apiRef.current = {
        sendDocLoaded: () => {},
        seekTo: () => {},
        flush: () => {}
      }
    }
  }, [book.id, virtualizer])

  return apiRef.current
}

function publishParagraphsForPage(
  page: number,
  pageDataMap: Record<number, import('react-pdf').TextContent>
): void {
  const data = pageDataMap[page]
  if (!data) return
  const newCurrent = pageDataToParagraphs(page, data)
  const nextData = pageDataMap[page + 1]
  const newNext = nextData ? pageDataToParagraphs(page + 1, nextData) : []
  const prevData = pageDataMap[page - 1]
  const newPrev = prevData ? pageDataToParagraphs(page - 1, prevData) : []

  const pdfState = usePdfStore.getState()
  if (!isEqual(pdfState.currentViewParagraphs, newCurrent)) {
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
}
