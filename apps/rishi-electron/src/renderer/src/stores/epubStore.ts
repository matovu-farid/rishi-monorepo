import { create } from 'zustand'
import { devtools, subscribeWithSelector } from 'zustand/middleware'
import type Rendition from 'epubjs/types/rendition'
import { ThemeType } from '@/themes/common'
import {
  getAllParagraphsForBook,
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs
} from '@/modules/epubwrapper'
import { usePlayerStore } from '@/stores/playerStore'
import { processEpubJob } from '@/modules/process_epub'
import { hasSavedEpubData, type BookOutline } from '@/lib/api'
import { useChatStore } from './chatStore'
import { prefetchRealtimeKey } from '@/modules/realtime'
import { voiceChatService } from '@/modules/voiceChatService'
import { captureError } from '@/utils/sentry'

export { ThemeType }

// Module-level timers for debouncing next/prev paragraph prefetch.
// Separate timers so the subscription and publishCurrentEpubParagraphs()
// don't cancel each other's debounce.
let _prefetchTimer: ReturnType<typeof setTimeout> | null = null
let _publishPrefetchTimer: ReturnType<typeof setTimeout> | null = null

interface EpubState {
  rendition: Rendition | null
  paragraphRendition: Rendition | null
  bookId: string
  currentEpubLocation: string
  theme: ThemeType
  renditionCount: number
  bookOutline: BookOutline | null

  setRendition: (rendition: Rendition | null) => void
  setParagraphRendition: (rendition: Rendition | null) => void
  setBookId: (id: string) => void
  setCurrentEpubLocation: (location: string) => void
  setTheme: (theme: ThemeType) => void
  incrementRenditionCount: () => void
  setBookOutline: (outline: BookOutline | null) => void
  reset: () => void
}

export const useEpubStore = create<EpubState>()(
  devtools(
    subscribeWithSelector((set) => ({
      rendition: null,
      paragraphRendition: null,
      bookId: '',
      currentEpubLocation: '',
      theme: ThemeType.White,
      renditionCount: 0,
      bookOutline: null,

      setRendition: (rendition) => set({ rendition }),
      setParagraphRendition: (paragraphRendition) => set({ paragraphRendition }),
      setBookId: (bookId) => set({ bookId }),
      setBookOutline: (bookOutline) => set({ bookOutline }),
      setCurrentEpubLocation: (currentEpubLocation) => set({ currentEpubLocation }),
      setTheme: (theme) => set({ theme }),
      incrementRenditionCount: () => set((state) => ({ renditionCount: state.renditionCount + 1 })),
      reset: () => {
        // Cancel any pending prefetch timers
        if (_prefetchTimer) {
          clearTimeout(_prefetchTimer)
          _prefetchTimer = null
        }
        if (_publishPrefetchTimer) {
          clearTimeout(_publishPrefetchTimer)
          _publishPrefetchTimer = null
        }
        set({
          rendition: null,
          paragraphRendition: null,
          bookId: '',
          currentEpubLocation: '',
          renditionCount: 0
        })
      }
    })),
    { name: 'epub-store' }
  )
)

// NOTE: NEXT_PAGE_PARAGRAPHS_EMPTIED and PREVIOUS_PAGE_PARAGRAPHS_EMPTIED
// are handled in epub.tsx (which also manages highlights and publishes PAGE_CHANGED).
// The location update happens via the ReactReader locationChanged callback.
// Do NOT add duplicate handlers here — it causes double page navigation and audio desync.

/**
 * Re-publish the current epub paragraphs to the event bus.
 * Call this after Player.initialize() to seed the Player with
 * paragraphs that were published before it subscribed.
 */
export function publishCurrentEpubParagraphs() {
  const { rendition, currentEpubLocation } = useEpubStore.getState()
  if (!rendition || !currentEpubLocation) return

  const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
    text: p.text,
    index: p.cfiRange
  }))
  usePlayerStore.getState().setCurrentParagraphs(paragraphs)

  // Use a separate timer so re-publish doesn't cancel the subscription's debounce
  if (_publishPrefetchTimer) clearTimeout(_publishPrefetchTimer)
  _publishPrefetchTimer = setTimeout(() => {
    const { rendition: r } = useEpubStore.getState()
    if (!r) return

    void getNextViewParagraphs(r)
      .then((nextParagraphs) => {
        const mapped = nextParagraphs.map((p) => ({
          text: p.text,
          index: p.cfiRange
        }))
        usePlayerStore.getState().setNextPageParagraphs(mapped)
      })
      .catch((err) => console.warn('[epub] republish next paragraph fetch failed:', err))

    void getPreviousViewParagraphs(r)
      .then((prevParagraphs) => {
        const mapped = prevParagraphs.map((p) => ({
          text: p.text,
          index: p.cfiRange
        }))
        usePlayerStore.getState().setPrevPageParagraphs(mapped)
      })
      .catch((err) => console.warn('[epub] republish prev paragraph fetch failed:', err))
  }, 300)
}

/**
 * Subscription lifecycle management.
 * These subscriptions drive side effects (paragraph processing, TTS paragraph
 * publishing, realtime key prefetch, and chat session start). They must be
 * initialised when the epub view mounts and torn down when it unmounts so
 * they don't fire for previously-opened books after navigation.
 */
let _unsubscribers: (() => void)[] = []

export function initEpubSubscriptions(): (() => void)[] {
  cleanupEpubSubscriptions() // Clean up any existing subscriptions

  const unsubs: (() => void)[] = []

  // Side effect: when paragraphRendition + bookId are set, process all paragraphs
  unsubs.push(
    useEpubStore.subscribe(
      (state) => ({ paragraphRendition: state.paragraphRendition, bookId: state.bookId }),
      (current, previous) => {
        const { paragraphRendition, bookId } = current
        if (
          paragraphRendition &&
          bookId &&
          (paragraphRendition !== previous.paragraphRendition || bookId !== previous.bookId)
        ) {
          void hasSavedEpubData({ bookId: Number(bookId) })
            .then((hasSaved) => {
              if (!hasSaved) {
                void getAllParagraphsForBook(paragraphRendition, bookId)
                  .then((paragraphs) => {
                    void processEpubJob(Number(bookId), paragraphs)
                  })
                  .catch((err) => captureError(err, { operation: 'epub', step: 'get_paragraphs' }))
              }
            })
            .catch((err) => captureError(err, { operation: 'epub', step: 'check_saved_data' }))
        }
      },
      {
        equalityFn: (a, b) => a.paragraphRendition === b.paragraphRendition && a.bookId === b.bookId
      }
    )
  )

  // Side effect: when rendition + location change, publish current/next/prev paragraphs.
  // Current-page paragraphs are published immediately (needed for TTS playback).
  // Next/prev page paragraphs are debounced to avoid wasted work during rapid page flips.
  unsubs.push(
    useEpubStore.subscribe(
      (state) => ({ rendition: state.rendition, location: state.currentEpubLocation }),
      (current) => {
        const { rendition, location } = current
        if (!rendition || !location) return

        // Current page — publish immediately (Player needs these to play)
        const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
          text: p.text,
          index: p.cfiRange
        }))
        usePlayerStore.getState().setCurrentParagraphs(paragraphs)

        // Next/prev pages — short debounce to skip rapid page flips while keeping
        // TTS prefetch responsive (was 300ms, reduced for faster audio pre-caching)
        if (_prefetchTimer) clearTimeout(_prefetchTimer)
        _prefetchTimer = setTimeout(() => {
          // Re-read state in case rendition changed during the debounce window
          const { rendition: r } = useEpubStore.getState()
          if (!r) return

          void getNextViewParagraphs(r)
            .then((nextParagraphs) => {
              const mapped = nextParagraphs.map((p) => ({
                text: p.text,
                index: p.cfiRange
              }))
              usePlayerStore.getState().setNextPageParagraphs(mapped)
            })
            .catch((err) => console.warn('[epub] next paragraph fetch failed:', err))

          void getPreviousViewParagraphs(r)
            .then((prevParagraphs) => {
              const mapped = prevParagraphs.map((p) => ({
                text: p.text,
                index: p.cfiRange
              }))
              usePlayerStore.getState().setPrevPageParagraphs(mapped)
            })
            .catch((err) => console.warn('[epub] prev paragraph fetch failed:', err))
        }, 50)
      },
      { equalityFn: (a, b) => a.rendition === b.rendition && a.location === b.location }
    )
  )

  // Side effect: pre-fetch the realtime API key when a book is opened; dispose the voice
  // session when the book closes. We register TWO cleanups: the subscription unsubscribe
  // and an explicit dispose. The explicit dispose is required because React unmounts the
  // view (which triggers cleanupEpubSubscriptions) BEFORE the route's bookId reset fires,
  // so the subscription would otherwise miss the transition to ''.
  //
  // NOTE: Outline is no longer fetched here via IPC. EpubView populates it via the
  // epubjs TOC callback (tocChanged prop on ReactReader). The outline subscription
  // below triggers preconnect once the outline arrives from that callback.
  const unsubBookId = useEpubStore.subscribe(
    (state) => state.bookId,
    (bookId) => {
      if (bookId) {
        prefetchRealtimeKey()
        // Outline is populated by EpubView via the epubjs TOC callback.
        // We just need to wait for it before preconnecting — subscribe below.
      } else {
        useEpubStore.getState().setBookOutline(null)
        voiceChatService.dispose()
      }
    }
  )
  unsubs.push(unsubBookId)
  unsubs.push(() => voiceChatService.dispose())

  // When the outline arrives (from EpubView's tocChanged), preconnect if appropriate
  unsubs.push(
    useEpubStore.subscribe(
      (state) => state.bookOutline,
      (outline) => {
        const bookId = useEpubStore.getState().bookId
        if (!bookId || !outline) return
        const pageText = usePlayerStore
          .getState()
          .currentParagraphs.map((p) => p.text)
          .join('\n')
        void voiceChatService.preconnect(Number(bookId), { pageText, outline })
      }
    )
  )

  // Side effect: when isChatting turns on and bookId exists, start realtime session
  unsubs.push(
    useChatStore.subscribe(
      (state) => state.isChatting,
      (isChatting) => {
        const bookId = useEpubStore.getState().bookId
        if (isChatting && bookId) {
          useChatStore.getState().startChat(Number(bookId))
        }
      }
    )
  )

  // Track in module-level array for cleanupEpubSubscriptions()
  _unsubscribers = unsubs
  return unsubs
}

export function cleanupEpubSubscriptions() {
  _unsubscribers.forEach((unsub) => unsub())
  _unsubscribers = []
}
