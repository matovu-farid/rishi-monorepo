import Loader from '@/components/Loader'
import { ReactReader } from '@/components/react-reader'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ThemeType } from '@/themes/common'
import { themes } from '@/themes/themes'
import createIReactReaderTheme from '@/themes/readerThemes'
import AIChatOrb from '../chat/AIChatOrb'
import VoiceChatLauncher from '../chat/VoiceChatLauncher'
import TTSControls from '@/components/tts/TTSControls'
import { useChatStore } from '@/stores/chatStore'
import type { Rendition } from 'epubjs'
import { PageCurlOverlay } from '../pagecurl/PageCurlOverlay'
import { usePageCurl } from '../pagecurl/usePageCurl'
import { useEpubStore, initEpubSubscriptions } from '@/stores/epubStore'
import { usePlayerStore } from '@/stores/playerStore'
import { useNavMachine } from '@/hooks/useNavMachine'
import { useNavStore } from '@/stores/navStore'
import { highlightRange, removeHighlight, getCurrentViewParagraphs } from '@/modules/epubwrapper'
import { type Book } from '@/lib/api'
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
  renditionRef.current = rendition

  // Boot the centralised navigation state machine
  useNavMachine(rendition)
  const navSend = useNavStore((s) => s.send)

  const pageCurl = usePageCurl({
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
  const bookSyncIdRef = useRef<string | null>(null)
  const [bookSyncId, setBookSyncId] = useState<string>('')
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
  const [selectionInfo, setSelectionInfo] = useState<{
    cfiRange: string
    text: string
    position: { x: number; y: number }
  } | null>(null)
  const [highlightsPanelOpen, setHighlightsPanelOpen] = useState(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()

  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const queryClient = useQueryClient()

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. EPUB has no thumbnails or
  // dual-page so those commands are not registered here.
  const menuHandlers = useMemo(
    () => ({
      toggleTOC: () => setTocOpen((v) => !v),
      addBookmark: () => {
        if (!bookSyncId) return
        void toggleBookmark({
          bookSyncId,
          location: currentLocation,
          label: pageCurrent ? `Page ${pageCurrent}` : undefined
        })
          .then(async () => {
            queryClient.invalidateQueries({ queryKey: ['bookmarks', bookSyncId] })
            await publishBookmarksToMenu(bookSyncId)
          })
          .catch((err) => console.warn('[menu] addBookmark failed:', err))
      },
      readAloudToggle: () => {
        const send = usePlayerStore.getState().send
        if (!send) return
        const state = usePlayerStore.getState().playingState
        if (state === 'playing') send({ type: 'PAUSE' })
        else if (state.startsWith('paused')) send({ type: 'RESUME' })
        else requireAuth('tts', () => send({ type: 'PLAY' }))
      },
      openChat: () => requireAuth('chat', () => setChatPanelOpen((v) => !v)),
      voiceChat: () => {
        const { isChatting: chatting, setIsChatting } = useChatStore.getState()
        if (chatting) setIsChatting(false)
        else requireAuth('voice-input', () => setIsChatting(true))
      }
    }),
    [requireAuth, bookSyncId, currentLocation, pageCurrent, queryClient]
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
          bytes = new Uint8Array(Object.values(data as Record<string, number>))
        }
        setEpubData(bytes)
      })
      .catch((err) => console.error('[epub] Failed to load:', err))
    return () => {
      cancelled = true
    }
  }, [book.filepath, epubData])

  // Look up the book's sync_id for highlight storage and bookmark functionality
  useEffect(() => {
    void window.electron.booksGetSyncId(book.id).then((syncId) => {
      bookSyncIdRef.current = syncId
      if (syncId) setBookSyncId(syncId)
    })
  }, [book.id])

  // Publish bookmarks to the menu context once sync_id is known. The
  // addBookmark menu handler re-publishes after edits.
  useEffect(() => {
    if (!bookSyncId) return
    void publishBookmarksToMenu(bookSyncId)
  }, [bookSyncId])

  // Publish title so the native Window menu sees the loaded book.
  useEffect(() => {
    const e = (window as unknown as { electron: { send(c: string, p: unknown): void } }).electron
    e?.send('window:setBookTitle', { bookId: book.id, title: book.title })
  }, [book.id, book.title])

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
  }, [rendition])

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

      setSelectionInfo({ cfiRange, text: selectedText, position: { x, y } })
    },
    [rendition]
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
        .catch((err) => console.warn('[highlight] save failed:', err))
      setSelectionInfo(null)
    },
    [selectionInfo, rendition]
  )

  async function clearAllHighlights() {
    const r = renditionRef.current
    if (!r) return
    const paragraphs = getCurrentViewParagraphs(r)
    return Promise.all(paragraphs.map((paragraph) => removeHighlight(r, paragraph.cfiRange)))
  }
  const setBookId = useEpubStore((s) => s.setBookId)
  const setBookOutline = useEpubStore((s) => s.setBookOutline)
  useEffect(() => {
    setBookId(book.id.toString())
    usePageTracker.getState().initBook(book.id.toString())
  }, [book.id])

  const handleTocChange = useCallback(
    (toc: NavItem[]) => {
      setBookOutline({
        title: book.title,
        author: book.author ?? null,
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

    // Try to consume a pending pageRequest through the nav machine.
    // Only succeeds when the machine is idle; otherwise leaves the
    // request in place so the navState retry subscription (below) can
    // pick it up when the machine returns to idle.
    const tryConsumePageRequest = async () => {
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
    }

    const unsubPage = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      () => {
        void tryConsumePageRequest()
      }
    )

    // Retry pending pageRequest when the nav machine returns to idle
    const unsubNavRetry = useNavStore.subscribe(
      (s) => s.navState,
      (state) => {
        if (state === 'idle') void tryConsumePageRequest()
      }
    )

    const unsubActive = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      async (paragraph) => {
        if (!paragraph) return
        await highlightRange(rendition, paragraph.index)
      }
    )

    const unsubEnded = usePlayerStore.subscribe(
      (s) => s.endedParagraph,
      async (paragraph) => {
        if (!paragraph) return
        await removeHighlight(rendition, paragraph.index)
      }
    )

    const unsubMove = usePlayerStore.subscribe(
      (s) => s.lastMove,
      async (move) => {
        if (!move) return
        await removeHighlight(rendition, move.from.index)
      }
    )

    const unsubState = usePlayerStore.subscribe(
      (s) => s.playingState,
      async (state) => {
        if (state === 'stopped' || state === 'idle') {
          await clearAllHighlights()
        }
      }
    )

    return () => {
      unsubPage()
      unsubNavRetry()
      unsubActive()
      unsubEnded()
      unsubMove()
      unsubState()
    }
  }, [rendition])

  useEffect(() => {
    if (rendition) {
      updateTheme(rendition, theme)
    }
  }, [theme])

  // Track cover page & recalculate avgLocsPerPage on resize/aspect ratio change
  useEffect(() => {
    if (!rendition) return

    const onRelocated = () => {
      const loc = (rendition as any).location
      const spineIndex = loc?.start?.index ?? -1
      setIsFirstPage(spineIndex === 0)
      setIsFrontMatter(spineIndex <= 1) // Hide page number on cover + title page
    }

    // Remeasure avgLocsPerPage when layout changes (resize, orientation)
    const onResized = () => {
      const pt = usePageTracker.getState()
      if (!pt.ready || !pt.locationsReady) return
      const startCfi = (rendition as any)?.location?.start?.cfi
      const endCfi = (rendition as any)?.location?.end?.cfi
      if (startCfi && endCfi) {
        const s = rendition.book.locations.locationFromCfi(startCfi) as unknown as number
        const e = rendition.book.locations.locationFromCfi(endCfi) as unknown as number
        if (typeof s === 'number' && typeof e === 'number' && e > s) {
          const rawLocCount = ((rendition.book.locations as any)._locations ?? []).length
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

            // Only save to DB after rendition has settled at the saved position.
            // Transient positions during initial load must not overwrite the saved CFI.
            if (settledRef.current) {
              updateBookLocationMutation.mutate({
                bookId: book.id.toString(),
                location: epubcfi
              })
              getSyncService().triggerWrite()
            }

            setCurrentEpubLocation(epubcfi)

            // Track page from actual CFI position (only after locations are generated)
            const pt = usePageTracker.getState()
            if (pt.ready && pt.locationsReady) {
              pt.goToCfi(
                epubcfi,
                (c: string) =>
                  (rendition?.book.locations.locationFromCfi(c) as unknown as number) ?? 0
              )
            }
          }}
          swipeable={true}
          readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
          handleTextSelected={handleTextSelected}
          getRendition={(_rendition) => {
            updateTheme(_rendition, theme)

            // Make the cover (first spine section) appear on the right side
            // of the first two-page spread by injecting a blank column spacer.
            _rendition.hooks.content.register((contents: any) => {
              if (contents.sectionIndex === 0) {
                const doc = contents.document as Document
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
                const startCfi = (_rendition as any)?.location?.start?.cfi
                const endCfi = (_rendition as any)?.location?.end?.cfi
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
                  const cfi = (_rendition as any)?.location?.start?.cfi
                  if (cfi) {
                    usePageTracker.getState().goToCfi(cfi, locFromCfi)
                    // Ensure the epub store has the location even when
                    // locationChanged is skipped (book opens at saved position).
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
                  ((_rendition.book.locations as any)._locations ?? []).length
                )
                usePageTracker.getState().setLocationsReady(true)

                // Cache raw locations for instant restore next time
                try {
                  localStorage.setItem(locsCacheKey, _rendition.book.locations.save())
                } catch {}

                // Wait for relocated so we can measure locsPerView
                const buildOnce = () => {
                  _rendition.off('relocated', buildOnce)
                  const rawLocCount = ((_rendition.book.locations as any)._locations ?? []).length
                  const avgLocsPerPage = measureLocsPerView()
                  console.log('[epub] Building page tracker:', { rawLocCount, avgLocsPerPage })
                  usePageTracker.getState().build(rawLocCount, avgLocsPerPage)
                  console.log('[epub] Page tracker state:', usePageTracker.getState())

                  // Seed current page
                  const startCfi = (_rendition as any)?.location?.start?.cfi
                  if (startCfi) {
                    usePageTracker.getState().goToCfi(startCfi, locFromCfi)
                    // Ensure the epub store has the location even when
                    // locationChanged is skipped (book opens at saved position).
                    setCurrentEpubLocation(startCfi)
                  }
                  settledRef.current = true
                }

                // Always wait for relocated — it fires after epub.js navigates
                // to the saved location, ensuring location.start.cfi is correct
                _rendition.on('relocated', buildOnce)
              })
            })
          }}
        />
        {pageCurl.active && (
          <PageCurlOverlay
            progress={pageCurl.progress}
            direction={pageCurl.direction}
            pageColor={themes[theme].background}
          />
        )}
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
            swipeable={true}
            readerStyles={createIReactReaderTheme(themes[theme].readerTheme)}
            getRendition={(_rendition) => {
              _rendition.once('rendered', () => {
                setParagraphRendition(_rendition)
              })
            }}
          />
        </div>
      </div>

      {/* AI chat orb */}
      {isChatting && (
        <AIChatOrb chatStatus={chatStatus} onClick={() => setChatPanelOpen((prev) => !prev)} />
      )}

      {/* Voice chat launcher — paired above the TTS play orb */}
      <VoiceChatLauncher />

      {/* TTS Controls — visually hidden while AI chat is active (stays mounted to avoid audio cleanup) */}
      <div style={{ display: isChatting ? 'none' : 'contents' }}>
        <TTSControls bookId={book.id.toString()} />
      </div>

      {/* Highlight color picker popover */}
      {selectionInfo && (
        <SelectionPopover
          cfiRange={selectionInfo.cfiRange}
          selectedText={selectionInfo.text}
          position={selectionInfo.position}
          onHighlight={handleHighlightColor}
          onClose={() => setSelectionInfo(null)}
        />
      )}

      {/* Highlights side panel */}
      <HighlightsPanel
        bookSyncId={bookSyncIdRef.current ?? ''}
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
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={rendition}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />

      {/* Page number indicator — shows "X" normally, "X of Y" on hover; hidden on front matter */}
      {pageReady && !isFrontMatter && (
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
      )}
    </div>
  )
}
