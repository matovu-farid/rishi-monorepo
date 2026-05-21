import type React from 'react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { getMobiChapter, getMobiChapterCount, getMobiText, updateBookLocation } from '@/lib/api'
import type { Book } from '@/lib/api'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { themes } from '@/themes/themes'
import type { PageDataInsertable } from '@/services'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'
import { stringToNumberID } from '@/lib/utils'
import { useBookSyncId } from '@/hooks/reader/useBookSyncId'
import { useReaderMenuSync } from '@/hooks/reader/useReaderMenuSync'
import { useCommonMenuHandlers } from '@/hooks/reader/useCommonMenuHandlers'
import { useChapterParagraphPrefetch } from '@/hooks/reader/useChapterParagraphPrefetch'
import { usePageRequestSubscription } from '@/hooks/reader/usePageRequestSubscription'
import ReaderOverlayControls from '@/components/reader/ReaderOverlayControls'
import { useBookEmbeddings } from '@/hooks/reader/useBookEmbeddings'
import { usePlayerStore } from '@/stores/playerStore'
import {
  navigationHistoryActor,
  onResumeRequested
} from '@/machines/navigationHistory/navigationHistoryActor'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'

export default function MobiView({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [tocOpen, setTocOpen] = useState(false)
  const [chapterIndex, setChapterIndex] = useState(() => {
    const parsed = Number(book.location)
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0
  })
  const [chapterCount, setChapterCount] = useState(0)
  const iframeRef = useRef<HTMLIFrameElement>(null)
  // Root ref for engagement detector pointer listeners
  const readerRootRef = useRef<HTMLDivElement>(null)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const { bookSyncId } = useBookSyncId(book.id)

  const queryClient = useQueryClient()

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. MOBI has no thumbnails or
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
        const idx = chapterIndex
        void toggleBookmark({
          bookSyncId,
          location: String(idx),
          label: `Chapter ${idx + 1}`
        })
          .then(async () => {
            void queryClient.invalidateQueries({ queryKey: ['bookmarks', bookSyncId] })
            await publishBookmarksToMenu(bookSyncId)
          })
          .catch((err: unknown) => console.warn('[menu] addBookmark failed:', err))
      }
    }),
    [commonHandlers, bookSyncId, chapterIndex, queryClient]
  )
  useMenuCommands(menuHandlers)

  // Set bookId for voice chat
  const setBookId = useEpubStore((s) => s.setBookId)
  useEffect(() => {
    setBookId(book.id.toString())
  }, [book.id, setBookId])

  // Mirror reader state (book title, TOC open, TTS playing) into the native menu.
  useReaderMenuSync({ book, tocOpen })

  // Navigation history: lifecycle (BOOK_OPENED / BOOK_CLOSED)
  useEffect(() => {
    navigationHistoryActor.send({
      type: 'BOOK_OPENED',
      bookId: String(book.id),
      initialPosition: { kind: 'mobi', cfi: String(chapterIndex) }
    })
    return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.id])

  // Navigation history: PAGE_VISITED on every chapter change
  useEffect(() => {
    const activeParagraph = usePlayerStore.getState().activeParagraph
    const indexStr = activeParagraph?.index
    const paragraphIndex = indexStr != null ? Number(indexStr) : null
    const ttsContext =
      paragraphIndex != null && Number.isFinite(paragraphIndex) ? { paragraphIndex } : null
    navigationHistoryActor.send({
      type: 'PAGE_VISITED',
      position: { kind: 'mobi', cfi: String(chapterIndex) },
      ttsContext
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chapterIndex])

  // Navigation history: RESUME_REQUESTED → navigate to the stored chapter
  useEffect(() => {
    return onResumeRequested((anchor) => {
      if (anchor.position.kind !== 'mobi') return
      const idx = parseInt(anchor.position.cfi, 10)
      if (Number.isFinite(idx) && idx >= 0) {
        setChapterIndex(idx)
      }
    })
  }, [])

  // Engagement detector (pointer-based dwell tracking)
  useEngagementDetector({ targetRef: readerRootRef, enabled: true })
  // Keyboard back-navigation (Alt+ArrowLeft / mouse button 3)
  useNavigationHistoryKeyboard()

  // Fetch total chapter count on mount
  useEffect(() => {
    getMobiChapterCount({ path: book.filepath })
      .then((count) => setChapterCount(count))
      .catch((err: unknown) => {
        console.error('[MobiView] failed to get chapter count:', err)
        toast.error('Failed to load MOBI chapter count')
      })
  }, [book.filepath])

  // Fetch chapter HTML when index changes. Using TanStack Query lets us
  // derive `loading` from query state instead of calling setLoading(true)
  // synchronously inside a useEffect (which trips react-hooks/set-state-in-effect).
  const {
    data: chapterHtml = '',
    isPending: chapterPending,
    error: chapterError
  } = useQuery({
    queryKey: ['mobi-chapter', book.filepath, chapterIndex],
    queryFn: () => getMobiChapter({ path: book.filepath, chapterIndex }),
    enabled: chapterCount > 0
  })
  const loading = chapterCount === 0 || chapterPending
  useEffect(() => {
    if (chapterError) {
      console.error('[MobiView] failed to get chapter:', chapterError)
      toast.error('Failed to load chapter')
    }
  }, [chapterError])

  // Persist reading position. Destructure `mutate` so the effect's dep array
  // doesn't pull in the unstable mutation result
  // (@tanstack/query/no-unstable-deps).
  const { mutate: persistLocationMutate } = useMutation({
    mutationFn: async (index: number) => {
      await updateBookLocation({
        bookId: book.id,
        newLocation: String(index)
      })
    },
    onError() {
      toast.error('Failed to save reading position')
    }
  })

  useEffect(() => {
    persistLocationMutate(chapterIndex)
  }, [chapterIndex, persistLocationMutate])

  // Navigation helpers
  const goNext = useCallback(() => {
    setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1))
  }, [chapterCount])

  const goPrev = useCallback(() => {
    setChapterIndex((prev) => Math.max(prev - 1, 0))
  }, [])

  // Keyboard navigation
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === 'ArrowRight') {
        goNext()
      } else if (e.key === 'ArrowLeft') {
        goPrev()
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [goNext, goPrev])

  // Publish paragraphs to playerStore for TTS.
  // Current chapter is published immediately; next/prev are debounced
  // so rapid chapter flips don't trigger wasted fetches.
  useChapterParagraphPrefetch({
    chapterIndex,
    chapterCount,
    indexPrefix: 'mobi',
    fetchCurrent: (idx) => getMobiText({ path: book.filepath, chapterIndex: idx }),
    fetchAt: (idx) => getMobiText({ path: book.filepath, chapterIndex: idx })
  })

  // Handle page-turn events from Player (TTS exhausted current chapter).
  usePageRequestSubscription({
    onNext: () => {
      if (chapterCount === 0) return
      setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1))
    },
    onPrev: () => {
      if (chapterCount === 0) return
      setChapterIndex((prev) => Math.max(prev - 1, 0))
    },
    autoClear: true
  })

  // Generate embeddings on first open (for AI chat)
  useBookEmbeddings({
    bookId: book.id,
    ready: chapterCount > 0,
    buildPageData: async () => {
      // Per-chapter extraction is independent; run in parallel.
      const chapters = await Promise.all(
        Array.from({ length: chapterCount }, async (_, i) => {
          const texts = await getMobiText({ path: book.filepath, chapterIndex: i })
          return { i, combined: texts.join('\n').trim() }
        })
      )
      const allPageData: PageDataInsertable[] = chapters
        .filter(({ combined }) => combined.length > 0)
        .map(({ i, combined }) => ({
          id: stringToNumberID(`${book.id}-mobi-${i}`),
          pageNumber: i + 1,
          bookId: book.id,
          data: combined
        }))
      return allPageData
    }
  })

  // Build themed srcdoc
  const srcdoc = useMemo(() => {
    const t = themes[theme]
    // Sanitize MOBI HTML: strip script tags and event handler attributes
    const sanitizedHtml = chapterHtml
      .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
      .replace(/\bon\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, '')
    return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  * { box-sizing: border-box; }
  body {
    background: ${t.background};
    color: ${t.color};
    font-family: Georgia, 'Times New Roman', serif;
    font-size: 1.2em;
    line-height: 1.8;
    padding: 2rem 3rem;
    max-width: 800px;
    margin: 0 auto;
  }
  img { max-width: 100%; height: auto; }
  a { color: inherit; }
  .page-number { text-align: center; font-size: 0.75em; color: ${t.color}; opacity: 0.4; padding: 2rem 0 1rem; }
</style>
</head>
<body>${sanitizedHtml}<div class="page-number">${chapterCount > 0 ? `${chapterIndex + 1} of ${chapterCount}` : ''}</div></body>
</html>`
  }, [chapterHtml, theme, chapterIndex, chapterCount])

  return (
    <div ref={readerRootRef} className="relative h-full">
    <div
      className="relative h-screen flex flex-col"
      style={{ background: themes[theme].background }}
    >
      {/* Main content area */}
      <div className="flex-1 overflow-hidden">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <div
              className="animate-spin rounded-full h-8 w-8 border-2 border-current border-t-transparent"
              style={{ color: themes[theme].color }}
            />
          </div>
        ) : (
          <iframe
            ref={iframeRef}
            srcDoc={srcdoc}
            className="w-full h-full border-none"
            title={book.title}
            sandbox="allow-same-origin"
          />
        )}
      </div>

      {/* Chapter navigation bar */}
      <div className="fixed bottom-20 left-1/2 -translate-x-1/2 z-10">
        <div className="flex items-center gap-3 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg">
          <button
            onClick={goPrev}
            disabled={chapterIndex <= 0}
            className="p-1 text-white disabled:opacity-30 hover:opacity-80 transition-opacity"
            aria-label="Previous chapter"
          >
            <ChevronLeft size={20} />
          </button>
          <span className="text-white text-sm font-medium min-w-[4rem] text-center">
            {chapterCount > 0 ? `${chapterIndex + 1} / ${chapterCount}` : '...'}
          </span>
          <button
            onClick={goNext}
            disabled={chapterIndex >= chapterCount - 1}
            className="p-1 text-white disabled:opacity-30 hover:opacity-80 transition-opacity"
            aria-label="Next chapter"
          >
            <ChevronRight size={20} />
          </button>
        </div>
      </div>

      {/* AI chat orb, voice chat launcher, and TTS controls */}
      <ReaderOverlayControls
        bookId={book.id.toString()}
        chatPanelOpen={chatPanelOpen}
        onChatOrbClick={() => setChatPanelOpen((prev) => !prev)}
      />

      {/* TOC / Bookmarks Sidebar */}
      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        title="Navigation"
        bookSyncId={bookSyncId}
        onBookmarkNavigate={(location) => {
          const idx = parseInt(location, 10)
          if (Number.isFinite(idx) && idx >= 0) {
            // Dispatch a JUMP_REQUESTED before navigating so the history
            // machine records the "from" anchor and can offer resume later.
            const activeParagraph = usePlayerStore.getState().activeParagraph
            const indexStr = activeParagraph?.index
            const paragraphIndex = indexStr != null ? Number(indexStr) : null
            const fromTts =
              paragraphIndex != null && Number.isFinite(paragraphIndex)
                ? { paragraphIndex }
                : null
            navigationHistoryActor.send({
              type: 'JUMP_REQUESTED',
              from: { kind: 'mobi', cfi: String(chapterIndex) },
              fromTts,
              to: { kind: 'mobi', cfi: location },
              source: 'bookmark',
              fromLabel: 'previous spot'
            })
            setChapterIndex(idx)
            setTocOpen(false)
          }
        }}
        tocContent={
          <div className="p-4 text-gray-400 text-sm text-center">
            Chapter {chapterIndex + 1} of {chapterCount}
          </div>
        }
      />

      {AuthDialog}

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncId}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />
    </div>
    <NavigationHistoryFooter />
    </div>
  )
}
