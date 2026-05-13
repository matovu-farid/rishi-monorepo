import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { hasSavedEpubData, updateBookLocation } from '@/lib/api'
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
import { parseAzw3, extractSectionParagraphs, type FoliateSection } from './parser'

function stringToNumberID(str: string): number {
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i)
    hash = ((hash << 5) - hash + ch) | 0
  }
  return Math.abs(hash)
}

export default function Azw3View({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [tocOpen, setTocOpen] = useState(false)
  const [chapterIndex, setChapterIndex] = useState(() => {
    const parsed = Number(book.location)
    return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : 0
  })
  const [sections, setSections] = useState<FoliateSection[]>([])
  const [chapterCount, setChapterCount] = useState(0)
  const [chapterUrl, setChapterUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const iframeRef = useRef<HTMLIFrameElement>(null)
  const embeddingsProcessedRef = useRef(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const bookSyncIdRef = useRef<string | null>(null)

  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const queryClient = useQueryClient()

  // Wire native-menu commands. Same surface as MobiView; AZW3 has no
  // thumbnails or dual-page so those commands are not registered.
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

  // Voice chat needs to know which book is active
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

  // Mirror TOC sheet state into the menu context.
  useEffect(() => {
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    if (!e) return
    e.setMenuContext({ tocOpen })
  }, [tocOpen])

  // Mirror TTS play state so the Reader > Read Aloud label flips while playing.
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

  // Parse the AZW3 file on mount. Bytes come straight off disk via the
  // existing readFile IPC; foliate-js handles the KF8 decoding in-renderer.
  useEffect(() => {
    let cancelled = false
    setLoading(true)
    ;(async () => {
      try {
        const bytes = await window.electron.readFile(book.filepath)
        const { sections: parsed } = await parseAzw3(bytes)
        if (cancelled) return
        setSections(parsed)
        setChapterCount(parsed.length)
        // Clamp persisted chapterIndex into the valid range. Books imported
        // via the test helper default to location='1' which would otherwise
        // overshoot for a single-section book.
        if (parsed.length > 0) {
          setChapterIndex((prev) => Math.min(Math.max(prev, 0), parsed.length - 1))
        }
        if (parsed.length === 0) {
          toast.error('AZW3 file has no readable sections')
          setLoading(false)
        }
      } catch (err) {
        if (cancelled) return
        console.error('[Azw3View] parse failed:', err)
        toast.error('Failed to load AZW3 book')
        setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [book.filepath])

  // Load the current chapter URL when chapterIndex changes.
  useEffect(() => {
    if (chapterCount === 0 || !sections[chapterIndex]) return
    let cancelled = false
    setLoading(true)
    const section = sections[chapterIndex]
    if (!section.load) {
      setLoading(false)
      return
    }
    section
      .load()
      .then((url) => {
        if (cancelled) return
        setChapterUrl(url)
        setLoading(false)
      })
      .catch((err) => {
        if (cancelled) return
        console.error('[Azw3View] failed to load section:', err)
        toast.error('Failed to load chapter')
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [sections, chapterIndex, chapterCount])

  // Persist reading position
  const updateLocationMutation = useMutation({
    mutationFn: async (index: number) => {
      await updateBookLocation({ bookId: book.id, newLocation: String(index) })
    },
    onError() {
      toast.error('Failed to save reading position')
    }
  })
  useEffect(() => {
    updateLocationMutation.mutate(chapterIndex)
  }, [chapterIndex])

  const goNext = useCallback(() => {
    setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1))
  }, [chapterCount])
  const goPrev = useCallback(() => {
    setChapterIndex((prev) => Math.max(prev - 1, 0))
  }, [])

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent): void {
      if (e.key === 'ArrowRight') goNext()
      else if (e.key === 'ArrowLeft') goPrev()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [goNext, goPrev])

  // Publish paragraphs to playerStore for TTS. Current chapter immediately,
  // next/prev debounced to avoid wasted work on rapid chapter flips.
  const prefetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (chapterCount === 0 || !sections[chapterIndex]) return

    void extractSectionParagraphs(sections[chapterIndex]).then((texts) => {
      const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
        text,
        index: `azw3-${chapterIndex}-${i}`
      }))
      usePlayerStore.getState().setCurrentParagraphs(paragraphs)
    })

    if (prefetchTimerRef.current) clearTimeout(prefetchTimerRef.current)
    prefetchTimerRef.current = setTimeout(() => {
      if (chapterIndex < chapterCount - 1 && sections[chapterIndex + 1]) {
        void extractSectionParagraphs(sections[chapterIndex + 1]).then((texts) => {
          const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
            text,
            index: `azw3-${chapterIndex + 1}-${i}`
          }))
          usePlayerStore.getState().setNextPageParagraphs(paragraphs)
        })
      } else {
        usePlayerStore.getState().setNextPageParagraphs([])
      }
      if (chapterIndex > 0 && sections[chapterIndex - 1]) {
        void extractSectionParagraphs(sections[chapterIndex - 1]).then((texts) => {
          const paragraphs: ParagraphWithIndex[] = texts.map((text, i) => ({
            text,
            index: `azw3-${chapterIndex - 1}-${i}`
          }))
          usePlayerStore.getState().setPrevPageParagraphs(paragraphs)
        })
      } else {
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }, 300)

    return () => {
      if (prefetchTimerRef.current) {
        clearTimeout(prefetchTimerRef.current)
        usePlayerStore.getState().setNextPageParagraphs([])
        usePlayerStore.getState().setPrevPageParagraphs([])
      }
    }
  }, [sections, chapterIndex, chapterCount])

  // Handle page-turn events from Player (TTS exhausted current chapter)
  useEffect(() => {
    const handleNextEmptied = (): void => {
      if (chapterCount === 0) return
      setChapterIndex((prev) => Math.min(prev + 1, chapterCount - 1))
    }
    const handlePrevEmptied = (): void => {
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
        // Virtual sections (paginateSection) all share a single source doc, so
        // emit a single combined entry per virtualGroupId instead of indexing
        // 87 near-duplicate per-page slices. This both saves time and keeps
        // the indexing pipeline aligned with the original section semantics.
        const seenGroups = new Set<string>()
        for (let i = 0; i < sections.length; i++) {
          const section = sections[i]
          if (section.virtualGroupId) {
            if (seenGroups.has(section.virtualGroupId)) continue
            seenGroups.add(section.virtualGroupId)
            const groupTexts: string[] = []
            for (let j = i; j < sections.length; j++) {
              if (sections[j].virtualGroupId !== section.virtualGroupId) break
              const texts = await extractSectionParagraphs(sections[j])
              for (const t of texts) groupTexts.push(t)
            }
            const combined = groupTexts.join('\n').trim()
            if (combined.length > 0) {
              allPageData.push({
                id: stringToNumberID(`${book.id}-azw3-${section.virtualGroupId}`),
                pageNumber: i + 1,
                bookId: book.id,
                data: combined
              })
            }
            continue
          }
          const texts = await extractSectionParagraphs(section)
          const combined = texts.join('\n').trim()
          if (combined.length > 0) {
            allPageData.push({
              id: stringToNumberID(`${book.id}-azw3-${i}`),
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
        console.warn('[Azw3View] failed to generate embeddings:', err)
      }
    })()
  }, [book.id, sections, chapterCount])

  // Themed iframe wrapping HTML loaded from foliate's section Blob URL.
  // Unlike the MOBI view (srcDoc + per-chapter HTML), foliate-js gives us
  // a fully-formed HTML doc URL — we use it directly as `src`. A small
  // postMessage-style theming pass is out of scope for now; the iframe
  // background color matches the theme via the wrapper div.
  const themeStyle = themes[theme]

  return (
    <div className="relative h-screen flex flex-col" style={{ background: themeStyle.background }}>
      <div className="flex-1 overflow-hidden">
        {loading ? (
          <div className="flex items-center justify-center h-full">
            <div
              className="animate-spin rounded-full h-8 w-8 border-2 border-current border-t-transparent"
              style={{ color: themeStyle.color }}
            />
          </div>
        ) : chapterUrl ? (
          <iframe
            ref={iframeRef}
            src={chapterUrl}
            className="w-full h-full border-none"
            title={book.title}
            sandbox="allow-same-origin"
            style={{ background: themeStyle.background }}
          />
        ) : null}
      </div>

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

      {isChatting && (
        <AIChatOrb chatStatus={chatStatus} onClick={() => setChatPanelOpen((prev) => !prev)} />
      )}

      <VoiceChatLauncher />

      <div style={{ display: isChatting ? 'none' : 'contents' }}>
        <TTSControls bookId={book.id.toString()} />
      </div>

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
