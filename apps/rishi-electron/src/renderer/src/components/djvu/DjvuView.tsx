import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { useQueryClient } from '@tanstack/react-query'
import {
  getDjvuPage,
  getDjvuPageCount,
  getDjvuPageText,
  hasSavedEpubData,
  updateBookLocation
} from '@/lib/api'
import type { Book } from '@/lib/api'
import TTSControls from '@/components/tts/TTSControls'
import { IconButton } from '@/components/ui/IconButton'
import { ChevronLeft, ChevronRight, ZoomIn, ZoomOut } from 'lucide-react'
import AIChatOrb from '../chat/AIChatOrb'
import VoiceChatLauncher from '../chat/VoiceChatLauncher'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex } from '@/models/player_control'
import { getBookImportService, type PageDataInsertable } from '@/services'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { stringToNumberID } from '@/lib/utils'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useChatStore } from '@/stores/chatStore'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'

const PAGE_CACHE_SIZE = 5
const MIN_ZOOM = 0.5
const MAX_ZOOM = 3.0
const ZOOM_STEP = 0.25
const DEFAULT_DPI = 150

interface PageCache {
  urls: Map<number, string>
  order: number[]
}

export function DjvuView({ book }: { book: Book }) {
  const [pageCount, setPageCount] = useState<number>(0)
  const [currentPage, setCurrentPage] = useState<number>(() => {
    const parsed = parseInt(book.location, 10)
    return parsed > 0 ? parsed : 1
  })
  const [zoom, setZoom] = useState<number>(1.0)
  const [loading, setLoading] = useState<boolean>(true)
  const [currentBlobUrl, setCurrentBlobUrl] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const cacheRef = useRef<PageCache>({ urls: new Map(), order: [] })
  const mountedRef = useRef(true)
  const embeddingsProcessedRef = useRef(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const [tocOpen, setTocOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const queryClient = useQueryClient()

  const bookSyncIdRef = useRef<string | null>(null)

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. DJVU has no thumbnails or
  // dual-page so those commands are not registered here.
  const menuHandlers = useMemo(
    () => ({
      toggleTOC: () => setTocOpen((v) => !v),
      addBookmark: () => {
        const syncId = bookSyncIdRef.current
        if (!syncId) return
        const page = currentPage
        void toggleBookmark({
          bookSyncId: syncId,
          location: String(page),
          label: `Page ${page}`
        })
          .then(async () => {
            queryClient.invalidateQueries({ queryKey: ['bookmarks', syncId] })
            await publishBookmarksToMenu(syncId)
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
    [requireAuth, currentPage, queryClient]
  )
  useMenuCommands(menuHandlers)

  // Set bookId for voice chat
  const setBookId = useEpubStore((s) => s.setBookId)
  useEffect(() => {
    setBookId(book.id.toString())
  }, [book.id, setBookId])

  // Look up the book's sync_id for chat + publish bookmarks to the menu.
  useEffect(() => {
    void window.electron.booksGetSyncId(book.id).then(async (syncId) => {
      bookSyncIdRef.current = syncId
      if (syncId) await publishBookmarksToMenu(syncId)
    })
  }, [book.id])

  // Publish title so the native Window menu sees the loaded book.
  useEffect(() => {
    const e = (window as unknown as { electron: { send(c: string, p: unknown): void } }).electron
    e?.send('window:setBookTitle', { bookId: book.id, title: book.title })
  }, [book.id, book.title])

  // Load total page count on mount
  useEffect(() => {
    mountedRef.current = true
    getDjvuPageCount({ path: book.filepath })
      .then((count) => {
        if (mountedRef.current) {
          setPageCount(count)
        }
      })
      .catch((err) => {
        if (mountedRef.current) {
          setError(`Failed to load DJVU: ${String(err)}`)
        }
      })

    return () => {
      mountedRef.current = false
      // Revoke all cached blob URLs on unmount
      const cache = cacheRef.current
      for (const url of cache.urls.values()) {
        URL.revokeObjectURL(url)
      }
      cache.urls.clear()
      cache.order = []
    }
  }, [book.filepath])

  const fetchPage = useCallback(
    async (pageNumber: number): Promise<string | null> => {
      const cache = cacheRef.current

      // Return cached URL if available
      const cached = cache.urls.get(pageNumber)
      if (cached) {
        return cached
      }

      try {
        const bytes = await getDjvuPage({
          path: book.filepath,
          pageNumber,
          dpi: DEFAULT_DPI
        })
        const uint8 = new Uint8Array(bytes)
        const blob = new Blob([uint8], { type: 'image/png' })
        const url = URL.createObjectURL(blob)

        // Add to cache
        cache.urls.set(pageNumber, url)
        cache.order.push(pageNumber)

        // Evict oldest entries if cache exceeds size
        while (cache.order.length > PAGE_CACHE_SIZE) {
          const evicted = cache.order.shift()!
          const evictedUrl = cache.urls.get(evicted)
          if (evictedUrl) {
            URL.revokeObjectURL(evictedUrl)
            cache.urls.delete(evicted)
          }
        }

        return url
      } catch (err) {
        console.error(`Failed to fetch DJVU page ${pageNumber}:`, err)
        return null
      }
    },
    [book.filepath]
  )

  // Load current page and prefetch neighbors
  useEffect(() => {
    if (pageCount === 0) return

    let cancelled = false
    setLoading(true)
    setError(null)

    void fetchPage(currentPage).then((url) => {
      if (cancelled || !mountedRef.current) return
      if (url) {
        setCurrentBlobUrl(url)
      } else {
        setError(`Failed to load page ${currentPage}`)
      }
      setLoading(false)
    })

    // Prefetch neighbors in background
    if (currentPage > 1) {
      void fetchPage(currentPage - 1)
    }
    if (currentPage < pageCount) {
      void fetchPage(currentPage + 1)
    }

    return () => {
      cancelled = true
    }
  }, [currentPage, pageCount, fetchPage])

  // Persist reading position
  useEffect(() => {
    if (pageCount === 0) return
    updateBookLocation({
      bookId: book.id,
      newLocation: String(currentPage)
    }).catch((err) => {
      console.error('Failed to persist reading position:', err)
    })
  }, [currentPage, book.id, pageCount])

  const goToPage = useCallback(
    (page: number) => {
      const clamped = Math.max(1, Math.min(page, pageCount))
      setCurrentPage(clamped)
    },
    [pageCount]
  )

  const goPrev = useCallback(() => goToPage(currentPage - 1), [currentPage, goToPage])
  const goNext = useCallback(() => goToPage(currentPage + 1), [currentPage, goToPage])

  const zoomIn = useCallback(() => {
    setZoom((z) => Math.min(MAX_ZOOM, +(z + ZOOM_STEP).toFixed(2)))
  }, [])

  const zoomOut = useCallback(() => {
    setZoom((z) => Math.max(MIN_ZOOM, +(z - ZOOM_STEP).toFixed(2)))
  }, [])

  // Keyboard navigation
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      // Ignore if user is typing in an input
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) {
        return
      }

      switch (e.key) {
        case 'ArrowLeft':
          e.preventDefault()
          goPrev()
          break
        case 'ArrowRight':
          e.preventDefault()
          goNext()
          break
        case '+':
        case '=':
          e.preventDefault()
          zoomIn()
          break
        case '-':
          e.preventDefault()
          zoomOut()
          break
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [goPrev, goNext, zoomIn, zoomOut])

  // Publish paragraphs to playerStore for TTS.
  // Current page is published immediately; next/prev are debounced
  // so rapid page flips don't trigger wasted fetches.
  const prefetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (pageCount === 0) return

    // Current page paragraphs — publish immediately
    getDjvuPageText({ path: book.filepath, pageNumber: currentPage })
      .then((texts) => {
        const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
          text,
          index: `djvu-${currentPage}-${i}`
        }))
        usePlayerStore.getState().setCurrentParagraphs(paragraphs)
      })
      .catch((err) => console.warn('[DjvuView] failed to get text for TTS:', err))

    // Debounce next/prev page prefetch
    if (prefetchTimerRef.current) clearTimeout(prefetchTimerRef.current)
    prefetchTimerRef.current = setTimeout(() => {
      // Prefetch next page paragraphs
      if (currentPage < pageCount) {
        getDjvuPageText({ path: book.filepath, pageNumber: currentPage + 1 })
          .then((texts) => {
            const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
              text,
              index: `djvu-${currentPage + 1}-${i}`
            }))
            usePlayerStore.getState().setNextPageParagraphs(paragraphs)
          })
          .catch((err) => console.warn('[DjvuView] failed to prefetch next page:', err))
      } else {
        usePlayerStore.getState().setNextPageParagraphs([])
      }

      // Prefetch previous page paragraphs
      if (currentPage > 1) {
        getDjvuPageText({ path: book.filepath, pageNumber: currentPage - 1 })
          .then((texts) => {
            const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
              text,
              index: `djvu-${currentPage - 1}-${i}`
            }))
            usePlayerStore.getState().setPrevPageParagraphs(paragraphs)
          })
          .catch((err) => console.warn('[DjvuView] failed to prefetch prev page:', err))
      } else {
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }, 300)

    return () => {
      if (prefetchTimerRef.current) {
        clearTimeout(prefetchTimerRef.current)
        // Clear stale prefetch data so Player doesn't use wrong page's paragraphs
        usePlayerStore.getState().setNextPageParagraphs([])
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }
  }, [book.filepath, currentPage, pageCount])

  // Handle page-turn events from Player (TTS exhausted current page)
  useEffect(() => {
    const handleNextEmptied = () => {
      if (pageCount === 0) return
      setCurrentPage((prev) => Math.min(prev + 1, pageCount))
    }
    const handlePrevEmptied = () => {
      if (pageCount === 0) return
      setCurrentPage((prev) => Math.max(prev - 1, 1))
    }

    const unsubPage = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      (request) => {
        if (request === 'next') handleNextEmptied()
        if (request === 'prev') handlePrevEmptied()
        if (request) usePlayerStore.getState().clearPageRequest()
      }
    )

    return () => {
      unsubPage()
    }
  }, [pageCount])

  // Generate embeddings on first open (for AI chat)
  useEffect(() => {
    if (pageCount === 0 || embeddingsProcessedRef.current) return
    embeddingsProcessedRef.current = true

    void (async () => {
      try {
        const alreadySaved = await hasSavedEpubData({ bookId: book.id })
        if (alreadySaved) return

        const allPageData: PageDataInsertable[] = []
        for (let page = 1; page <= pageCount; page++) {
          const texts = await getDjvuPageText({ path: book.filepath, pageNumber: page })
          const combined = texts.join('\n').trim()
          if (combined.length > 0) {
            allPageData.push({
              id: stringToNumberID(`${book.id}-djvu-${page}`),
              pageNumber: page,
              bookId: book.id,
              data: combined
            })
          }
        }

        if (allPageData.length > 0) {
          await getBookImportService().indexBook(book.id, allPageData)
        }
      } catch (err) {
        console.warn('[DjvuView] failed to generate embeddings:', err)
      }
    })()
  }, [book.id, book.filepath, pageCount])

  return (
    <div className="relative h-screen w-full flex flex-col bg-gray-900">
      {/* Main scrollable area */}
      <div className="flex-1 overflow-auto flex items-start justify-center pt-16 pb-24">
        {error && (
          <div className="text-red-400 text-center mt-20 px-4">
            <p>{error}</p>
          </div>
        )}

        {loading && !error && (
          <div className="text-white/60 text-center mt-20">
            <div className="animate-spin inline-block w-6 h-6 border-2 border-white/30 border-t-white rounded-full" />
            <p className="mt-2 text-sm">Loading page {currentPage}...</p>
          </div>
        )}

        {!loading && currentBlobUrl && !error && (
          <div
            className="transition-transform duration-150 origin-top"
            style={{ transform: `scale(${zoom})` }}
          >
            <img
              src={currentBlobUrl}
              alt={`Page ${currentPage} of ${book.title}`}
              className="max-w-full shadow-2xl"
              draggable={false}
            />
          </div>
        )}
      </div>

      {/* Bottom navigation bar */}
      <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50">
        <div className="flex items-center gap-2 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg shadow-lg border border-white/10">
          {/* Zoom controls */}
          <IconButton
            onClick={zoomOut}
            disabled={zoom <= MIN_ZOOM}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Zoom out"
          >
            <ZoomOut size={18} />
          </IconButton>

          <span className="text-white/80 text-sm font-mono min-w-[3.5rem] text-center select-none">
            {Math.round(zoom * 100)}%
          </span>

          <IconButton
            onClick={zoomIn}
            disabled={zoom >= MAX_ZOOM}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Zoom in"
          >
            <ZoomIn size={18} />
          </IconButton>

          {/* Divider */}
          <div className="w-px h-6 bg-white/20 mx-1" />

          {/* Page navigation */}
          <IconButton
            onClick={goPrev}
            disabled={currentPage <= 1}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Previous page"
          >
            <ChevronLeft size={20} />
          </IconButton>

          <span className="text-white/80 text-sm font-mono min-w-[4rem] text-center select-none">
            {currentPage} / {pageCount}
          </span>

          <IconButton
            onClick={goNext}
            disabled={currentPage >= pageCount}
            className="text-white hover:bg-white/10 disabled:text-white/30 border-none"
            aria-label="Next page"
          >
            <ChevronRight size={20} />
          </IconButton>
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
        <TTSControls key={book.id.toString()} bookId={book.id.toString()} />
      </div>

      {AuthDialog}

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />

      {/* Navigation / Bookmarks Sidebar */}
      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        title="Navigation"
        bookSyncId={bookSyncIdRef.current ?? ''}
        onBookmarkNavigate={(location) => {
          const page = parseInt(location, 10)
          if (page > 0) {
            setCurrentPage(page)
            setTocOpen(false)
          }
        }}
        tocContent={
          <div className="p-4 text-gray-400 text-sm text-center">
            Page {currentPage} of {pageCount}
          </div>
        }
      />
    </div>
  )
}

export default DjvuView
