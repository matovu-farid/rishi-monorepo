import Loader from '@/components/Loader'
import { ReactReader } from '@/components/react-reader'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import type React from 'react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ThemeType } from '@/themes/common'
import { themes } from '@/themes/themes'
import createIReactReaderTheme from '@/themes/readerThemes'
import ReaderOverlayControls from '@/components/reader/ReaderOverlayControls'
import type { Rendition } from 'epubjs'
import { PageCurlOverlay } from '../pagecurl/PageCurlOverlay'
import { useReaderGesture } from '../pagecurl/useReaderGesture'
import { useEpubStore, initEpubSubscriptions } from '@/stores/epubStore'
import { usePlayerStore } from '@/stores/playerStore'
import { useNavMachine } from '@/hooks/useNavMachine'
import { useNavStore } from '@/stores/navStore'
import { highlightRange, removeHighlight, getCurrentViewParagraphs } from '@/modules/epubwrapper'
import type { Book } from '@/lib/api'
import { updateBookLocation } from '@/lib/api'
import { saveHighlight, getHighlightsForBook } from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import { getHighlightHex } from '@/types/highlight'
import type { HighlightColor } from '@/types/highlight'
import type { Contents } from 'epubjs'
import type { NavItem } from 'epubjs'
import { tocToChapters } from './tocToChapters'
import { SelectionPopover } from '@/components/highlights/SelectionPopover'
import { HighlightsPanel } from '@/components/highlights/HighlightsPanel'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { BookmarksList } from '@/components/bookmarks/BookmarksList'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { ScrollArea } from '@/components/ui/scroll-area'
import { usePageTracker } from '@/modules/epub-page-tracker'
import { dumpError } from '@/utils/errorDump'
import { getCachedEpub } from '@/services/reader-cache/epub-cache'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'
import { useBookSyncId } from '@/hooks/reader/useBookSyncId'
import { useReaderMenuSync } from '@/hooks/reader/useReaderMenuSync'
import { useCommonMenuHandlers } from '@/hooks/reader/useCommonMenuHandlers'
import { usePageRequestSubscription } from '@/hooks/reader/usePageRequestSubscription'
import { useSelectionStore } from '@/stores/selectionStore'
import { findParagraphForCfi } from '@/modules/cfi-to-paragraph'
import { buildPartialFirst } from '@/modules/read-aloud-from'

function updateTheme(rendition: Rendition, theme: ThemeType) {
  const reditionThemes = rendition.themes
  reditionThemes.override('color', themes[theme].color)
  reditionThemes.override('background', themes[theme].background)
  reditionThemes.override('font-size', '1.2em')
}

export default function EpubView({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [currentLocation, setCurrentLocation] = useState<string>(book.location || '0')
  // Sync with book.location when it changes from a refetch (e.g., returning from library).
  // Only sync before the rendition has settled to avoid overriding user navigation.
  const bookLocationRef = useRef(book.location)
  useEffect(() => {
    if (book.location && book.location !== bookLocationRef.current && !settledRef.current) {
      bookLocationRef.current = book.location
      setCurrentLocation(book.location)
      dumpError({
        source: 'epub:syncLocation',
        location: 'refetch',
        error: JSON.stringify({ newLocation: book.location })
      })
    }
  }, [book.location])
  const rendition = useEpubStore((s) => s.rendition)
  const setRendition = useEpubStore((s) => s.setRendition)
  const renditionRef = useRef(rendition)
  // Mirror the latest rendition into a ref via effect — writing refs during
  // render violates react-hooks/refs.
  useEffect(() => {
    renditionRef.current = rendition
  }, [rendition])

  // Boot the centralised navigation state machine
  useNavMachine(rendition)
  const navSend = useNavStore((s) => s.send)

  // Flip userNavHappenedRef the first time the nav machine leaves 'idle'.
  // navState !== 'idle' implies a genuine user-initiated navigation
  // (CURL_NEXT/CURL_PREV clicks, DISPLAY jumps from TOC/bookmarks, or
  // TTS-driven page turns). Restore-drift relocateds happen outside the
  // nav machine and so will NOT flip this ref.
  useEffect(() => {
    const unsub = useNavStore.subscribe(
      (s) => s.navState,
      (state) => {
        if (!userNavHappenedRef.current && state !== 'idle') {
          userNavHappenedRef.current = true
        }
      }
    )
    return unsub
  }, [])

  // Window-close flush. The save chain is async: click Next → page-curl
  // animation (~200ms) → rendition.next() resolves → 'relocated' fires →
  // mutation IPC. If the user closes the window mid-flight, the new CFI
  // never reaches SQLite. The main process intercepts the window 'close'
  // event and calls window.__rishi.flushPendingSaves(); this handler waits
  // briefly for any in-flight nav to settle, then writes the latest known
  // CFI directly via the synchronous IPC (no mutation queue).
  useEffect(() => {
    const flush = async (): Promise<void> => {
      // Wait up to 800ms for any in-flight navigation to settle so we
      // capture the click that triggered the close, not the position
      // before it. Total close-flush budget is 1.5s in the main process,
      // so keep this strictly less than that to leave room for the IPC
      // round-trip.
      const waitStart = Date.now()
      while (useNavStore.getState().navState !== 'idle' && Date.now() - waitStart < 800) {
        // eslint-disable-next-line no-await-in-loop -- Sequential settle poll.
        await new Promise<void>((r) => {
          setTimeout(r, 50)
        })
      }
      // Prefer the rendition's live position (it has the freshest CFI
      // after rendition.next() resolves). Fall back to whatever
      // locationChanged last published.
      const liveCfi = renditionRef.current?.location.start.cfi
      const cfi = liveCfi ?? lastSavedCfiRef.current ?? undefined
      if (!cfi) return
      // Only flush if the user actually navigated this session — never
      // overwrite the saved position with a restore-drift CFI.
      if (!userNavHappenedRef.current || !settledRef.current) return
      try {
        await window.electron.updateBookLocation(book.id, cfi)
      } catch (err) {
        console.error('[flushPendingSaves] save failed', err)
      }
    }
    const w = window as unknown as {
      __rishi?: { flushPendingSaves?: () => Promise<void> }
    }
    w.__rishi = w.__rishi ?? {}
    w.__rishi.flushPendingSaves = flush
    return () => {
      if (w.__rishi?.flushPendingSaves === flush) {
        delete w.__rishi.flushPendingSaves
      }
    }
  }, [book.id])

  const pageCurl = useReaderGesture({
    onNavigate: (dir) => {
      // Reject if the nav machine is busy — prevents double rendition calls
      if (useNavStore.getState().navState !== 'idle' || !navSend) return false
      // Clear any pending player page request to avoid double navigation
      usePlayerStore.getState().clearPageRequest()
      navSend({ type: dir === 'right' ? 'CURL_NEXT' : 'CURL_PREV' })
      return true
    },
    onCommit: () => {
      navSend?.({ type: 'CURL_COMMIT' })
    },
    onUndoNavigate: () => {
      navSend?.({ type: 'CURL_CANCEL' })
    }
  })
  const { bookSyncId, bookSyncIdRef } = useBookSyncId(book.id)
  const [bookmarksPanelOpen, setBookmarksPanelOpen] = useState(false)
  const [tocOpen, setTocOpen] = useState(false)
  const pageReady = usePageTracker((s) => s.ready)
  const pageCurrent = usePageTracker((s) => s.current)
  const pageTotal = usePageTracker((s) => s.total)
  const [isFirstPage, setIsFirstPage] = useState(false)
  const [isFrontMatter, setIsFrontMatter] = useState(false)
  // Don't save location to DB until rendition has settled at the saved position.
  // Without this, the transient initial position overwrites the correct saved CFI.
  const settledRef = useRef(false)
  // Tracks whether the user has initiated at least one navigation this mount.
  // Combined with settledRef, this prevents restore-drift "relocated" events
  // (which can fire at a different CFI than the saved one) from overwriting
  // the saved position in the DB.
  const userNavHappenedRef = useRef(false)
  // Latest CFI we've observed from a `locationChanged` callback. Updated on
  // every published location and read by the window-close flush handler.
  const lastSavedCfiRef = useRef<string | null>(null)
  const [selectionInfo, setSelectionInfo] = useState<{
    cfiRange: string
    text: string
    position: { x: number; y: number }
  } | null>(null)
  const [highlightsPanelOpen, setHighlightsPanelOpen] = useState(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()

  const queryClient = useQueryClient()

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. EPUB has no thumbnails or
  // dual-page so those commands are not registered here.
  const commonHandlers = useCommonMenuHandlers({
    // useRequireAuth narrows the feature key to PremiumFeature; the hook
    // accepts a plain string so it can be shared across views without
    // dragging the auth-features types into the primitive.
    requireAuth: requireAuth as (feature: string, action: () => void) => void,
    setChatPanelOpen,
    setTocOpen
  })
  const menuHandlers = useMemo(
    () => ({
      ...commonHandlers,
      addBookmark: () => {
        if (!bookSyncId) return
        void toggleBookmark({
          bookSyncId,
          location: currentLocation,
          label: pageCurrent ? `Page ${pageCurrent}` : undefined
        })
          .then(async () => {
            void queryClient.invalidateQueries({ queryKey: ['bookmarks', bookSyncId] })
            await publishBookmarksToMenu(bookSyncId)
          })
          .catch((err: unknown) => console.warn('[menu] addBookmark failed:', err))
      },
      readAloudFromSelection: () => {
        const sel = useSelectionStore.getState().current
        if (sel) {
          window.dispatchEvent(new CustomEvent('rishi:readAloudFromSelection'))
        } else {
          commonHandlers.readAloudToggle?.()
        }
      }
    }),
    [commonHandlers, bookSyncId, currentLocation, pageCurrent, queryClient]
  )
  useMenuCommands(menuHandlers)

  // Load EPUB bytes via IPC. The lazy initializer reads the warm-restore
  // cache synchronously so a reopen renders with bytes (and the cached
  // parsed Book downstream) on the very first paint — no loader flash.
  const [epubData, setEpubData] = useState<Uint8Array | null>(
    () => getCachedEpub(book.id)?.bytes ?? null
  )
  useEffect(() => {
    if (epubData) return
    let cancelled = false
    window.electron
      .readFile(book.filepath)
      .then((data) => {
        if (cancelled) return
        let bytes: Uint8Array
        if (data instanceof ArrayBuffer) {
          bytes = new Uint8Array(data)
        } else if (ArrayBuffer.isView(data)) {
          bytes = new Uint8Array(
            (data as ArrayBufferView).buffer,
            (data as ArrayBufferView).byteOffset,
            (data as ArrayBufferView).byteLength
          )
        } else {
          bytes = new Uint8Array(Object.values(data))
        }
        setEpubData(bytes)
      })
      .catch((err: unknown) => console.error('[epub] Failed to load:', err))
    return () => {
      cancelled = true
    }
  }, [book.filepath, epubData])

  // Mirror reader state (book title, TOC open, TTS playing) into the native menu.
  useReaderMenuSync({ book, tocOpen })

  // Load persisted highlights when rendition is ready
  useEffect(() => {
    if (!rendition || !bookSyncIdRef.current) return
    const syncId = bookSyncIdRef.current
    void getHighlightsForBook(syncId).then((highlights) => {
      for (const hl of highlights) {
        const hex = getHighlightHex(hl.color as HighlightColor)
        void highlightRange(rendition, hl.cfiRange, {}, () => {}, 'epubjs-hl', {
          fill: hex,
          'fill-opacity': '0.3',
          'mix-blend-mode': 'multiply'
        })
      }
    })
  }, [rendition, bookSyncIdRef])

  // Handle user text selection -- show color picker popover instead of auto-highlight
  const handleTextSelected = useCallback(
    (cfiRange: string, contents: Contents) => {
      const syncId = bookSyncIdRef.current
      if (!syncId || !rendition) return

      const selection = contents.window.getSelection()
      const selectedText = selection?.toString() ?? ''
      if (!selectedText.trim()) return

      // Get selection position for popover placement
      const range = selection?.getRangeAt(0)
      const rect = range?.getBoundingClientRect()
      const iframeEl = contents.document.defaultView?.frameElement
      const iframeRect = iframeEl?.getBoundingClientRect()
      const x = (rect?.left ?? 0) + (iframeRect?.left ?? 0)
      const y = (rect?.top ?? 0) + (iframeRect?.top ?? 0) - 50

      useSelectionStore.getState().setEpubSelection({ cfiRange, text: selectedText })
      setSelectionInfo({ cfiRange, text: selectedText, position: { x, y } })
    },
    [rendition, bookSyncIdRef]
  )

  // Handle color selection from the popover
  const handleHighlightColor = useCallback(
    (color: HighlightColor) => {
      if (!selectionInfo || !rendition || !bookSyncIdRef.current) return
      const hex = getHighlightHex(color)
      void highlightRange(rendition, selectionInfo.cfiRange, {}, () => {}, 'epubjs-hl', {
        fill: hex,
        'fill-opacity': '0.3',
        'mix-blend-mode': 'multiply'
      })
      void saveHighlight({
        bookSyncId: bookSyncIdRef.current,
        cfiRange: selectionInfo.cfiRange,
        text: selectionInfo.text,
        color
      })
        .then(() => getSyncService().triggerWrite())
        .catch((err: unknown) => console.warn('[highlight] save failed:', err))
      setSelectionInfo(null)
      useSelectionStore.getState().clear()
    },
    [selectionInfo, rendition, bookSyncIdRef]
  )

  const handleReadAloudFrom = useCallback(() => {
    const sel = useSelectionStore.getState().current
    if (!sel || sel.format !== 'epub') return

    const playingState = usePlayerStore.getState().playingState
    if (playingState === 'idle' || playingState === 'pageNavigating') return

    const paragraphs = usePlayerStore.getState().currentParagraphs
    if (paragraphs.length === 0) return

    const matched = findParagraphForCfi(paragraphs, sel.cfiRange)

    const send = usePlayerStore.getState().send
    if (!send) return

    requireAuth('tts', () => {
      if (!matched) {
        // Selection not in any current paragraph — fall back to paragraph 0
        // of current view with no override.
        const first = paragraphs[0]
        send({
          type: 'PLAY_FROM',
          paragraphIndex: 0,
          partialFirstText: first.text,
          partialFirstKey: first.index
        })
        return
      }

      const targetParagraph = paragraphs[matched.paragraphIndex]
      const { partialFirstText, partialFirstKey } = buildPartialFirst(
        targetParagraph.index,
        targetParagraph.text,
        matched.charOffsetInParagraph
      )
      send({
        type: 'PLAY_FROM',
        paragraphIndex: matched.paragraphIndex,
        partialFirstText,
        partialFirstKey
      })
    })

    // Clear selection store; the popover may still be visible briefly but
    // will close on its own.
    useSelectionStore.getState().clear()
  }, [requireAuth])

  // Subscribe to the context-menu IPC event that fires when the user clicks
  // "Read Aloud From Here" in the native right-click menu (Task 9/10).
  useEffect(() => {
    const unsubscribe = window.electron.on('reader:readAloudFromSelection', () => {
      handleReadAloudFrom()
    })
    return unsubscribe
  }, [handleReadAloudFrom])

  // Subscribe to the window CustomEvent dispatched by the ⌘⇧L menu shortcut
  // (Task 11). Both the IPC path (context menu) and this path converge on
  // the same handleReadAloudFrom adapter.
  useEffect(() => {
    const handler = (): void => {
      handleReadAloudFrom()
    }
    window.addEventListener('rishi:readAloudFromSelection', handler)
    return () => window.removeEventListener('rishi:readAloudFromSelection', handler)
  }, [handleReadAloudFrom])

  const clearAllHighlights = useCallback(async () => {
    const r = renditionRef.current
    if (!r) return
    return Promise.all(
      getCurrentViewParagraphs(r).map((paragraph) => removeHighlight(r, paragraph.cfiRange))
    )
  }, [])

  // Try to consume a pending pageRequest through the nav machine.
  // Only succeeds when the machine is idle; otherwise leaves the
  // request in place so the navState retry subscription (in the
  // rendition effect below) can pick it up when the machine returns
  // to idle. Stable across renders so usePageRequestSubscription's
  // ref-based callback dispatch isn't churned.
  const tryConsumePageRequest = useCallback(async () => {
    // Hook is bound at component scope before rendition resolves; guard
    // against running before there's anything to navigate.
    if (!renditionRef.current) return
    const request = usePlayerStore.getState().pageRequest
    if (!request) return
    const { navState, send } = useNavStore.getState()
    if (navState !== 'idle' || !send) return
    await clearAllHighlights()
    // Re-check after async highlight removal — machine may have
    // become busy in the meantime.
    if (useNavStore.getState().navState !== 'idle') return
    send({ type: request === 'next' ? 'NEXT' : 'PREV' })
    // Only clear if the request hasn't been replaced by a new one
    // during the await window (the player could set a fresh request
    // while clearAllHighlights was in-flight).
    if (usePlayerStore.getState().pageRequest === request) {
      usePlayerStore.getState().clearPageRequest()
    }
  }, [clearAllHighlights])

  // Route player page-turn requests through the nav machine.
  // autoClear: false — tryConsumePageRequest clears the request itself
  // (only when its guards succeed, to preserve the navState-retry path).
  usePageRequestSubscription({
    onNext: tryConsumePageRequest,
    onPrev: tryConsumePageRequest,
    autoClear: false
  })

  const setBookId = useEpubStore((s) => s.setBookId)
  const setBookOutline = useEpubStore((s) => s.setBookOutline)
  useEffect(() => {
    setBookId(book.id.toString())
    usePageTracker.getState().initBook(book.id.toString())
  }, [book.id, setBookId])

  const handleTocChange = useCallback(
    (toc: NavItem[]) => {
      setBookOutline({
        title: book.title,
        author: book.author,
        chapters: tocToChapters(toc)
      })
    },
    [book.title, book.author, setBookOutline]
  )

  // Manage epubStore subscription lifecycle — init on mount, cleanup on unmount.
  // Use a component-local ref so rapid navigation doesn't cause cleanup to wipe
  // new subscriptions (the module-level array is shared across mounts).
  const unsubsRef = useRef<(() => void)[]>([])

  useEffect(() => {
    unsubsRef.current = initEpubSubscriptions()
    return () => {
      unsubsRef.current.forEach((fn) => fn())
      unsubsRef.current = []
    }
  }, [])

  useEffect(() => {
    if (!rendition) return

    // Retry pending pageRequest when the nav machine returns to idle.
    // (The pageRequest subscription itself lives in
    // usePageRequestSubscription at the top of the component.)
    const unsubNavRetry = useNavStore.subscribe(
      (s) => s.navState,
      (state) => {
        if (state === 'idle') void tryConsumePageRequest()
      }
    )

    const unsubActive = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      (paragraph) => {
        if (!paragraph) return
        void highlightRange(rendition, paragraph.index)
      }
    )

    const unsubEnded = usePlayerStore.subscribe(
      (s) => s.endedParagraph,
      (paragraph) => {
        if (!paragraph) return
        void removeHighlight(rendition, paragraph.index)
      }
    )

    const unsubMove = usePlayerStore.subscribe(
      (s) => s.lastMove,
      (move) => {
        if (!move) return
        void removeHighlight(rendition, move.from.index)
      }
    )

    const unsubState = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        if (state === 'stopped' || state === 'idle') {
          void clearAllHighlights()
        }
      }
    )

    return () => {
      unsubNavRetry()
      unsubActive()
      unsubEnded()
      unsubMove()
      unsubState()
    }
  }, [rendition, tryConsumePageRequest, clearAllHighlights])

  useEffect(() => {
    if (rendition) {
      updateTheme(rendition, theme)
    }
  }, [theme, rendition])

  // Track cover page & recalculate avgLocsPerPage on resize/aspect ratio change
  useEffect(() => {
    if (!rendition) return

    const onRelocated = () => {
      const loc = rendition.location
      const spineIndex = loc.start.index
      setIsFirstPage(spineIndex === 0)
      setIsFrontMatter(spineIndex <= 1) // Hide page number on cover + title page
    }

    // Remeasure avgLocsPerPage when layout changes (resize, orientation)
    const onResized = () => {
      const pt = usePageTracker.getState()
      if (!pt.ready || !pt.locationsReady) return
      const startCfi = rendition.location.start.cfi
      const endCfi = rendition.location.end.cfi
      if (startCfi && endCfi) {
        const s = rendition.book.locations.locationFromCfi(startCfi) as unknown as number
        const e = rendition.book.locations.locationFromCfi(endCfi) as unknown as number
        if (typeof s === 'number' && typeof e === 'number' && e > s) {
          const rawLocCount = rendition.book.locations._locations.length
          pt.build(rawLocCount, e - s)
        }
      }
    }

    rendition.on('relocated', onRelocated)
    rendition.on('resized', onResized)
    return () => {
      rendition.off('relocated', onRelocated)
      rendition.off('resized', onResized)
    }
  }, [rendition])

  const setCurrentEpubLocation = useEpubStore((s) => s.setCurrentEpubLocation)

  const setParagraphRendition = useEpubStore((s) => s.setParagraphRendition)

  const updateBookLocationMutation = useMutation({
    mutationFn: async ({ bookId, location }: { bookId: string; location: string }) => {
      await updateBookLocation({
        bookId: Number(bookId),
        newLocation: location
      })
    },
    onSuccess(_data, variables) {
      void queryClient.invalidateQueries({ queryKey: ['book', variables.bookId] })
    },
    onError(_error) {
      toast.error('Can not change book page')
    }
  })
  // Update rendition state when ref becomes available

  // Show loading state while EPUB data is being fetched
  if (!epubData) {
    return (
      <div className="w-full h-screen grid items-center">
        <Loader />
      </div>
    )
  }

  return (
    <div className="relative">
      <div
        style={{ height: '100vh', position: 'relative', overflow: 'hidden', touchAction: 'pan-y' }}
        {...pageCurl.pointerHandlers}
        {...pageCurl.wheelHandlers}
      >
        <ReactReader
          key={`reader-${book.id}`}
          bookCacheKey={book.id}
          showToc={true}
          bookSyncId={bookSyncId}
          tocExpanded={tocOpen}
          onTocExpandedChange={setTocOpen}
          onNext={() => pageCurl.autoTurn('right')}
          onPrev={() => pageCurl.autoTurn('left')}
          hidePrev={isFirstPage}
          tocChanged={handleTocChange}
          loadingView={
            <div className="w-full h-screen grid items-center">
              <Loader />
            </div>
          }
          url={epubData}
          title={book.title}
          location={currentLocation || book.location || 0}
          locationChanged={(epubcfi: string) => {
            setCurrentLocation(epubcfi)

            // Dump every locationChanged for debugging
            dumpError({
              source: 'epub:locationChanged',
              location: 'locationChanged',
              error: JSON.stringify({
                epubcfi,
                settled: settledRef.current,
                bookLocation: book.location
              })
            })

            // Only save to DB after rendition has settled at the saved position
            // AND the user has performed at least one navigation. Restore-drift
            // relocateds can fire at a column-start CFI that differs from the
            // saved one; without the userNav gate they would silently
            // overwrite the correct saved CFI on reopen.
            if (settledRef.current && userNavHappenedRef.current) {
              updateBookLocationMutation.mutate({
                bookId: book.id.toString(),
                location: epubcfi
              })
              getSyncService().triggerWrite()
              // Record the latest CFI so the window-close flush has a value
              // to write even if the mutation above hasn't completed yet.
              // eslint-disable-next-line react-hooks/immutability -- Refs are mutable by design; the lint rule misfires on this standard pattern.
              lastSavedCfiRef.current = epubcfi
            }

            setCurrentEpubLocation(epubcfi)

            // Track page from actual CFI position (only after locations are generated)
            const pt = usePageTracker.getState()
            if (pt.ready && pt.locationsReady) {
              pt.goToCfi(
                epubcfi,
                (c: string) =>
                  (rendition?.book.locations.locationFromCfi(c) as unknown as number | undefined) ??
                  0
              )
            }
          }}
          swipeable={false}
          readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
          handleTextSelected={handleTextSelected}
          getRendition={(_rendition) => {
            updateTheme(_rendition, theme)

            // Make the cover (first spine section) appear on the right side
            // of the first two-page spread by injecting a blank column spacer.
            _rendition.hooks.content.register((contents: Contents) => {
              if (contents.sectionIndex === 0) {
                const doc = contents.document
                const spacer = doc.createElement('div')
                spacer.setAttribute('data-cover-spacer', 'true')
                spacer.style.breakAfter = 'column'
                spacer.style.height = '100%'
                doc.body.insertBefore(spacer, doc.body.firstChild)
              }
            })

            _rendition.once('rendered', () => {
              setRendition(_rendition)
              const pt = usePageTracker.getState()

              const CHARS_PER_PAGE = 1600
              const locsCacheKey = `epub-locs-v5-${book.id}`
              // Clean up old cache versions
              localStorage.removeItem(`epub-locations-${book.id}`)
              localStorage.removeItem(`epub-locs-v2-${book.id}`)
              localStorage.removeItem(`epub-pages-v3-${book.id}`)
              localStorage.removeItem(`epub-pages-v4-${book.id}`)
              localStorage.removeItem(`epub-pages-v5-${book.id}`)

              const locFromCfi = (c: string) =>
                _rendition.book.locations.locationFromCfi(c) as unknown as number

              // Measure how many location markers fit in one visible spread
              const measureLocsPerView = (): number => {
                const startCfi = _rendition.location.start.cfi
                const endCfi = _rendition.location.end.cfi
                if (startCfi && endCfi) {
                  const s = locFromCfi(startCfi)
                  const e = locFromCfi(endCfi)
                  if (typeof s === 'number' && typeof e === 'number' && e > s) {
                    return e - s
                  }
                }
                return 2 // sensible default for two-page spread
              }

              // Try restoring locations from localStorage cache (instant)
              const cachedLocs = localStorage.getItem(locsCacheKey)
              if (cachedLocs && pt.ready) {
                // Restore epub.js locations instantly — no generate() needed
                _rendition.book.locations.load(cachedLocs)
                pt.setLocationsReady(true)

                // Wait for epub.js to navigate to the saved location before
                // reading position. "rendered" fires before display() completes,
                // so location.start.cfi is stale until "relocated" fires.
                const seedOnRelocated = () => {
                  _rendition.off('relocated', seedOnRelocated)
                  const cfi = _rendition.location.start.cfi
                  if (cfi) {
                    usePageTracker.getState().goToCfi(cfi, locFromCfi)
                    setCurrentEpubLocation(cfi)
                  }
                  settledRef.current = true
                }
                _rendition.on('relocated', seedOnRelocated)
                return
              }

              // No cache — generate locations (slow, first time only)
              console.log('[epub] Generating locations with CHARS_PER_PAGE:', CHARS_PER_PAGE)
              void _rendition.book.locations.generate(CHARS_PER_PAGE).then(() => {
                console.log(
                  '[epub] Locations generated, count:',
                  _rendition.book.locations._locations.length
                )
                usePageTracker.getState().setLocationsReady(true)

                // Cache raw locations for instant restore next time
                try {
                  localStorage.setItem(locsCacheKey, _rendition.book.locations.save())
                } catch {
                  // localStorage quota exceeded — non-fatal, locations will regenerate next time
                }

                // Run build/seed synchronously after generate() resolves. We
                // do NOT wait for a future 'relocated' event because if the
                // user makes no further click, that event may never arrive —
                // leaving settledRef false forever and dropping all saves.
                const rawLocCount = _rendition.book.locations._locations.length
                const avgLocsPerPage = measureLocsPerView()
                console.log('[epub] Building page tracker:', { rawLocCount, avgLocsPerPage })
                usePageTracker.getState().build(rawLocCount, avgLocsPerPage)
                console.log('[epub] Page tracker state:', usePageTracker.getState())

                // Seed current page from whatever the rendition is showing now.
                const startCfi = _rendition.location.start.cfi
                if (startCfi) {
                  usePageTracker.getState().goToCfi(startCfi, locFromCfi)
                  setCurrentEpubLocation(startCfi)
                }
                settledRef.current = true
                // If the user navigated during generation, flush the current
                // CFI to the DB — no future 'relocated' is guaranteed, so the
                // gated locationChanged handler may never get a chance to save.
                if (userNavHappenedRef.current && startCfi) {
                  updateBookLocationMutation.mutate({
                    bookId: book.id.toString(),
                    location: startCfi
                  })
                  getSyncService().triggerWrite()
                }
              })
            })
          }}
        />
        {pageCurl.active ? (
          <PageCurlOverlay
            progress={pageCurl.progress}
            direction={pageCurl.direction}
            pageColor={themes[theme].background}
          />
        ) : null}
      </div>
      <div className="fixed top-0 left-9999 right-9999 bottom-0 -z-30 pointer-events-none opacity-0">
        <div style={{ height: '100vh', position: 'relative', overflow: 'hidden' }}>
          <ReactReader
            key={`reader-paragraph-${book.id}`}
            handleKeyPress={() => {}}
            loadingView={
              <div className="w-full h-screen grid items-center">
                <Loader />
              </div>
            }
            url={epubData}
            title={book.title}
            location={currentLocation || book.location || 0}
            locationChanged={() => {}}
            swipeable={false}
            readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
            getRendition={(_rendition) => {
              _rendition.once('rendered', () => {
                setParagraphRendition(_rendition)
              })
            }}
          />
        </div>
      </div>

      {/* AI chat orb, voice chat launcher, and TTS controls */}
      <ReaderOverlayControls
        bookId={book.id.toString()}
        chatPanelOpen={chatPanelOpen}
        onChatOrbClick={() => setChatPanelOpen((prev) => !prev)}
      />

      {/* Highlight color picker popover */}
      {selectionInfo ? (
        <SelectionPopover
          cfiRange={selectionInfo.cfiRange}
          selectedText={selectionInfo.text}
          position={selectionInfo.position}
          onHighlight={handleHighlightColor}
          onReadAloudFrom={handleReadAloudFrom}
          onClose={() => {
            setSelectionInfo(null)
            useSelectionStore.getState().clear()
          }}
        />
      ) : null}

      {/* Highlights side panel */}
      <HighlightsPanel
        bookSyncId={bookSyncId}
        rendition={rendition}
        open={highlightsPanelOpen}
        onOpenChange={setHighlightsPanelOpen}
      />

      {/* Bookmarks side panel */}
      <Sheet open={bookmarksPanelOpen} onOpenChange={setBookmarksPanelOpen}>
        <SheetContent side="right" className="w-[400px] flex flex-col">
          <SheetHeader>
            <SheetTitle className="text-lg font-semibold">Bookmarks</SheetTitle>
          </SheetHeader>
          <ScrollArea className="flex-1 px-4">
            <BookmarksList
              bookSyncId={bookSyncId}
              onNavigate={(location) => {
                const send = useNavStore.getState().send
                if (send) send({ type: 'DISPLAY', location })
                setBookmarksPanelOpen(false)
              }}
            />
          </ScrollArea>
        </SheetContent>
      </Sheet>

      {AuthDialog}

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncId}
        bookTitle={book.title}
        rendition={rendition}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />

      {/* Page number indicator — shows "X" normally, "X of Y" on hover; hidden on front matter */}
      {pageReady && !isFrontMatter ? (
        <div
          className="group/page"
          style={{
            position: 'fixed',
            bottom: 0,
            left: 0,
            right: 0,
            textAlign: 'center',
            zIndex: 5,
            padding: '8px 0'
          }}
        >
          <span
            style={{
              fontSize: 12,
              color: themes[theme].color,
              opacity: 0.4
            }}
          >
            <span>{pageCurrent}</span>
            <span className="hidden group-hover/page:inline"> of {pageTotal}</span>
          </span>
        </div>
      ) : null}
    </div>
  )
}
