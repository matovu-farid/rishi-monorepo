import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import {
  getMobiChapter,
  getMobiChapterCount,
  getMobiText,
  hasSavedEpubData,
  updateBookLocation
} from '@/lib/api'
import type { Book } from '@/lib/api'
import TTSControls from '@/components/tts/TTSControls'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import AIChatOrb from '@/components/chat/AIChatOrb'
import VoiceChatLauncher from '@/components/chat/VoiceChatLauncher'
import { themes } from '@/themes/themes'
import { usePlayerStore } from '@/stores/playerStore'
import type { ParagraphWithIndex } from '@/models/player_control'
import { getBookImportService, type PageDataInsertable } from '@/services'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { useChatStore } from '@/stores/chatStore'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'

// Simple string hash function (replaces stringToNumberID from Tauri's xxhash64)
function stringToNumberID(str: string): number {
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i)
    hash = ((hash << 5) - hash + char) | 0
  }
  return Math.abs(hash)
}

export default function MobiView({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [tocOpen, setTocOpen] = useState(false)
  const [chapterIndex, setChapterIndex] = useState(() => {
    const parsed = Number(book.location)
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0
  })
  const [chapterCount, setChapterCount] = useState(0)
  const [chapterHtml, setChapterHtml] = useState('')
  const [loading, setLoading] = useState(true)
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const embeddingsProcessedRef = useRef(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const bookSyncIdRef = useRef<string | null>(null)

  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const queryClient = useQueryClient()

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. MOBI has no thumbnails or
  // dual-page so those commands are not registered here.
  const menuHandlers = useMemo(
    () => ({
      toggleTOC: () => setTocOpen((v) => !v),
      addBookmark: () => {
        const syncId = bookSyncIdRef.current
        if (!syncId) return
        const idx = chapterIndex
        void toggleBookmark({
          bookSyncId: syncId,
          location: String(idx),
          label: `Chapter ${idx + 1}`
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
    [requireAuth, chapterIndex, queryClient]
  )
  useMenuCommands(menuHandlers)

  // Set bookId for voice chat
  const setBookId = useEpubStore((s) => s.setBookId)
  useEffect(() => {
    setBookId(book.id.toString())
  }, [book.id, setBookId])

  // Look up the book's sync_id for chat + publish bookmarks for the menu.
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

  // Mirror TOC sheet state into the menu context so the View > Show TOC
  // checkbox flips with the actual sidebar state.
  useEffect(() => {
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    if (!e) return
    e.setMenuContext({ tocOpen })
  }, [tocOpen])

  // Mirror TTS play state into the menu so the Reader > Read Aloud label
  // flips to "Stop Read Aloud" while playback is active.
  useEffect(() => {
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    if (!e) return
    const unsub = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        e.setMenuContext({ isReading: state === 'playing' })
      }
    )
    e.setMenuContext({ isReading: usePlayerStore.getState().playingState === 'playing' })
    return unsub
  }, [])

  // Fetch total chapter count on mount
  useEffect(() => {
    getMobiChapterCount({ path: book.filepath })
      .then((count) => setChapterCount(count))
      .catch((err) => {
        console.error('[MobiView] failed to get chapter count:', err)
        toast.error('Failed to load MOBI chapter count')
      })
  }, [book.filepath])

  // Fetch chapter HTML when index changes
  useEffect(() => {
    if (chapterCount === 0) return
    setLoading(true)
    getMobiChapter({ path: book.filepath, chapterIndex })
      .then((html) => {
        setChapterHtml(html)
        setLoading(false)
      })
      .catch((err) => {
        console.error('[MobiView] failed to get chapter:', err)
        toast.error('Failed to load chapter')
        setLoading(false)
      })
  }, [book.filepath, chapterIndex, chapterCount])

  // Persist reading position
  const updateLocationMutation = useMutation({
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
    updateLocationMutation.mutate(chapterIndex)
  }, [chapterIndex])

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
  const prefetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (chapterCount === 0) return

    // Current chapter paragraphs — publish immediately
    getMobiText({ path: book.filepath, chapterIndex })
      .then((texts) => {
        const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
          text,
          index: `mobi-${chapterIndex}-${i}`
        }))
        usePlayerStore.getState().setCurrentParagraphs(paragraphs)
      })
      .catch((err) => console.warn('[MobiView] failed to get text for TTS:', err))

    // Debounce next/prev chapter prefetch
    if (prefetchTimerRef.current) clearTimeout(prefetchTimerRef.current)
    prefetchTimerRef.current = setTimeout(() => {
      // Prefetch next chapter paragraphs
      if (chapterIndex < chapterCount - 1) {
        getMobiText({ path: book.filepath, chapterIndex: chapterIndex + 1 })
          .then((texts) => {
            const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
              text,
              index: `mobi-${chapterIndex + 1}-${i}`
            }))
            usePlayerStore.getState().setNextPageParagraphs(paragraphs)
          })
          .catch((err) => console.warn('[MobiView] failed to prefetch next chapter:', err))
      } else {
        usePlayerStore.getState().setNextPageParagraphs([])
      }

      // Prefetch previous chapter paragraphs
      if (chapterIndex > 0) {
        getMobiText({ path: book.filepath, chapterIndex: chapterIndex - 1 })
          .then((texts) => {
            const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
              text,
              index: `mobi-${chapterIndex - 1}-${i}`
            }))
            usePlayerStore.getState().setPrevPageParagraphs(paragraphs)
          })
          .catch((err) => console.warn('[MobiView] failed to prefetch prev chapter:', err))
      } else {
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }, 300)

    return () => {
      if (prefetchTimerRef.current) {
        clearTimeout(prefetchTimerRef.current)
        // Clear stale prefetch data so Player doesn't use wrong chapter's paragraphs
        usePlayerStore.getState().setNextPageParagraphs([])
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }
  }, [book.filepath, chapterIndex, chapterCount])

  // Handle page-turn events from Player (TTS exhausted current chapter)
  useEffect(() => {
    const handleNextEmptied = () => {
      if (chapterCount === 0) return
      setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1))
    }
    const handlePrevEmptied = () => {
      if (chapterCount === 0) return
      setChapterIndex((prev) => Math.max(prev - 1, 0))
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
  }, [chapterCount])

  // Generate embeddings on first open (for AI chat)
  useEffect(() => {
    if (chapterCount === 0 || embeddingsProcessedRef.current) return
    embeddingsProcessedRef.current = true

    void (async () => {
      try {
        const alreadySaved = await hasSavedEpubData({ bookId: book.id })
        if (alreadySaved) return

        const allPageData: PageDataInsertable[] = []
        for (let i = 0; i < chapterCount; i++) {
          const texts = await getMobiText({ path: book.filepath, chapterIndex: i })
          const combined = texts.join('\n').trim()
          if (combined.length > 0) {
            allPageData.push({
              id: stringToNumberID(`${book.id}-mobi-${i}`),
              pageNumber: i + 1,
              bookId: book.id,
              data: combined
            })
          }
        }

        if (allPageData.length > 0) {
          await getBookImportService().indexBook(book.id, allPageData)
        }
      } catch (err) {
        console.warn('[MobiView] failed to generate embeddings:', err)
      }
    })()
  }, [book.id, book.filepath, chapterCount])

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

      {/* TOC / Bookmarks Sidebar */}
      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        title="Navigation"
        bookSyncId={bookSyncIdRef.current ?? ''}
        onBookmarkNavigate={(location) => {
          const idx = parseInt(location, 10)
          if (Number.isFinite(idx) && idx >= 0) {
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
        bookSyncId={bookSyncIdRef.current ?? ''}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />
    </div>
  )
}
