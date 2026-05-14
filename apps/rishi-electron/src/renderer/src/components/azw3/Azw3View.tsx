import type React from 'react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { hasSavedEpubData, updateBookLocation } from '@/lib/api'
import type { Book } from '@/lib/api'
import TTSControls from '@/components/tts/TTSControls'
import { NavigationArrows } from '@/components/react-reader/components'
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
import {
  parseAzw3,
  extractSectionParagraphs,
  stripKindleResourceLinks,
  type FoliateSection
} from './parser'
import { injectReaderStyles } from './reader-styles'
import { findParagraphElement, parseParagraphIndex, setActiveClass } from './highlight'
import { computePageStep, formatLocation, measurePageCount, parseLocation } from './pagination'

function stringToNumberID(str: string): number {
  let hash = 0
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i)
    hash = ((hash << 5) - hash + ch) | 0
  }
  return Math.abs(hash)
}

/** Debounce delay before persisting reading location. Page turns fire often
 *  (one per click + per TTS paragraph advance) so we coalesce updates. */
const LOCATION_PERSIST_DEBOUNCE_MS = 500

export default function Azw3View({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [tocOpen, setTocOpen] = useState(false)

  // Persisted reading position is now `<chapter>:<page>`. parseLocation
  // also accepts the legacy bare-integer form so reopening an existing book
  // doesn't reset the reader to the cover.
  const initialLocation = useMemo(() => parseLocation(book.location), [book.location])
  const [rawChapterIndex, setChapterIndex] = useState(initialLocation.chapter)
  const [pageWithinChapter, setPageWithinChapter] = useState(initialLocation.page)
  const [pagesInCurrentChapter, setPagesInCurrentChapter] = useState(1)

  // Parse the AZW3 file on mount. Bytes come straight off disk via the
  // existing readFile IPC; foliate-js handles the KF8 decoding in-renderer.
  // We use TanStack Query so `loading` is derived from query state instead
  // of calling setLoading inside an effect (react-hooks/set-state-in-effect).
  // Defined here (before the useMemo that wires native-menu commands) so
  // `chapterIndex` is in scope by the time menuHandlers references it.
  const {
    data: parseResult,
    isPending: parsePending,
    error: parseError
  } = useQuery({
    queryKey: ['azw3-parse', book.filepath],
    queryFn: async () => {
      const bytes = await window.electron.readFile(book.filepath)
      return parseAzw3(bytes)
    },
    staleTime: Infinity,
    gcTime: Infinity
  })
  const sections = useMemo<FoliateSection[]>(() => parseResult?.sections ?? [], [parseResult])
  const chapterCount = sections.length

  // Clamp persisted chapterIndex into the valid range as soon as we know
  // the section count. Books imported via the test helper default to
  // location='1' which would otherwise overshoot for a single-section book.
  // Derive the clamped value so the actual exposed `chapterIndex` is always
  // in range without needing a setState-in-effect to fix it up.
  const chapterIndex =
    chapterCount === 0 ? rawChapterIndex : Math.min(Math.max(rawChapterIndex, 0), chapterCount - 1)
  // Per-chapter measured page counts, keyed by chapterIndex. Built up
  // lazily as the user visits chapters (or as ResizeObserver re-measures
  // them). Unmeasured chapters contribute 0 to globalTotal — that's why
  // the visible "of N" defaults to '?' until at least one chapter is
  // measured.
  const [chapterPageCounts, setChapterPageCounts] = useState<Record<number, number>>({})

  const iframeRef = useRef<HTMLIFrameElement>(null)
  const embeddingsProcessedRef = useRef(false)
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const bookSyncIdRef = useRef<string | null>(null)
  // Mirror the sync id into state so JSX can read it without touching the
  // ref during render (react-hooks/refs).
  const [bookSyncId, setBookSyncId] = useState<string>('')

  // When navigating backward across a chapter boundary, we want to land on
  // the *last* page of the new chapter — but we can't know how many pages
  // that chapter has until it loads. Stash the request here and have the
  // load handler apply it.
  // Numeric values are explicit page offsets; 'last' means "last page",
  // resolved against the actual measured page count after layout settles.
  const pendingPageAfterLoadRef = useRef<number | 'last' | null>(null)

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
          location: formatLocation(idx, pageWithinChapter),
          label: `Chapter ${idx + 1}`
        })
          .then(async () => {
            void queryClient.invalidateQueries({ queryKey: ['bookmarks', syncId] })
            await publishBookmarksToMenu(syncId)
          })
          .catch((err: unknown) => console.warn('[menu] addBookmark failed:', err))
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
    [requireAuth, chapterIndex, pageWithinChapter, queryClient]
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
      if (syncId) {
        setBookSyncId(syncId)
        await publishBookmarksToMenu(syncId)
      }
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

  // Surface parse errors / empty-book to the user. This effect only reads
  // from query state and shows a toast — it does not call setState.
  useEffect(() => {
    if (parseError) {
      console.error('[Azw3View] parse failed:', parseError)
      toast.error('Failed to load AZW3 book')
    } else if (parseResult?.sections.length === 0) {
      toast.error('AZW3 file has no readable sections')
    }
  }, [parseError, parseResult])

  // Load the current chapter URL when chapterIndex changes. Using useQuery
  // here too so loading state is derived rather than imperatively set.
  const currentSection = sections[chapterIndex]
  const {
    data: chapterUrl = null,
    isPending: chapterPending,
    error: chapterError
  } = useQuery({
    queryKey: ['azw3-chapter', book.filepath, chapterIndex, currentSection],
    queryFn: async () => {
      if (!currentSection?.load) return null
      return currentSection.load()
    },
    enabled: chapterCount > 0 && !!currentSection
  })

  useEffect(() => {
    if (chapterError) {
      console.error('[Azw3View] failed to load section:', chapterError)
      toast.error('Failed to load chapter')
    }
  }, [chapterError])

  const loading =
    parsePending || (parseResult !== undefined && parseResult.sections.length > 0 && chapterPending)

  // Persist reading position — debounced. Page turns fire on every click
  // and on every TTS paragraph advance, so write at most once every 500ms.
  // Destructure `mutate` so the persist effect's dependency array can list
  // a referentially-stable function instead of the unstable mutation result
  // (@tanstack/query/no-unstable-deps).
  const { mutate: persistLocationMutate } = useMutation({
    mutationFn: async (loc: string) => {
      await updateBookLocation({ bookId: book.id, newLocation: loc })
    },
    onError() {
      toast.error('Failed to save reading position')
    }
  })
  const persistTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Hold a stable ref to the mutate fn so the persist effect doesn't re-run
  // every render. Refs are written from an effect (not during render) to
  // satisfy react-hooks/refs.
  const persistMutateRef = useRef(persistLocationMutate)
  useEffect(() => {
    persistMutateRef.current = persistLocationMutate
  }, [persistLocationMutate])
  useEffect(() => {
    if (persistTimerRef.current) clearTimeout(persistTimerRef.current)
    persistTimerRef.current = setTimeout(() => {
      persistMutateRef.current(formatLocation(chapterIndex, pageWithinChapter))
    }, LOCATION_PERSIST_DEBOUNCE_MS)
    return () => {
      if (persistTimerRef.current) {
        clearTimeout(persistTimerRef.current)
        // Flush on unmount so the last position is always saved even if the
        // user closes the book within the debounce window.
        persistMutateRef.current(formatLocation(chapterIndex, pageWithinChapter))
      }
    }
  }, [chapterIndex, pageWithinChapter])

  /**
   * Apply the desired `pageWithinChapter` to the iframe's body.scrollLeft.
   * `pageStep` is the horizontal stride between pages (clientWidth + columnGap)
   * — see computePageStep in ./pagination. Returns the page index that was
   * actually scrolled to (after clamping).
   */
  const applyScrollToPage = useCallback(
    (
      doc: Document,
      _iframeWin: Window,
      desiredPage: number,
      totalPages: number,
      pageStep: number
    ): number => {
      const clamped = Math.max(0, Math.min(desiredPage, totalPages - 1))
      const body = doc.body
      if (body) {
        const left = clamped * pageStep
        // `behavior: 'instant'` avoids the default smooth-scroll animation
        // (which feels sluggish on chapter switches and would race React).
        body.scrollTo({ left, top: 0, behavior: 'instant' as ScrollBehavior })
        // Fallback for engines that don't implement scrollTo on body.
        body.scrollLeft = left
      }
      return clamped
    },
    []
  )

  // Inject reader CSS, strip Kindle-internal resource refs, measure the
  // column-paginated chapter, and scroll to the desired page on every
  // iframe load. Runs on every chapter switch because the iframe is
  // remounted with a fresh contentDocument per chapterUrl.
  const handleIframeLoad = useCallback(() => {
    const iframe = iframeRef.current
    const doc = iframe?.contentDocument
    const iframeWin = iframe?.contentWindow
    if (!doc || !iframeWin) return
    injectReaderStyles(doc)
    // Foliate rewrites most kindle: URLs when serving section blobs, but
    // legacy stylesheet `<link>` tags survive and trigger CSP fetch errors
    // in the iframe. Drop them before measurement so they don't influence
    // layout.
    stripKindleResourceLinks(doc)

    const measureAndScroll = async (): Promise<void> => {
      // Wait for fonts and layout to settle before measuring scrollWidth.
      // Without this, the first measurement often comes back too small
      // because web-font loading shifts the column flow.
      try {
        await doc.fonts?.ready
      } catch {
        // doc.fonts might be undefined or throw in non-CSSFontLoading envs.
      }
      await new Promise<void>((resolve) => {
        iframeWin.requestAnimationFrame(() => resolve())
      })

      const body = doc.body
      // Column-aware stride: CSS multicol places a `column-gap` between every
      // pair of adjacent columns, INCLUDING between the last column of page N
      // and the first column of page N+1. Body also has horizontal padding
      // (`box-sizing: border-box`) so the stride is
      // `clientWidth - paddingLeft - paddingRight + columnGap` — see
      // computePageStep in ./pagination.
      const cs = body ? iframeWin.getComputedStyle(body) : null
      const columnGap = cs ? parseFloat(cs.columnGap || '0') || 0 : 0
      const paddingLeft = cs ? parseFloat(cs.paddingLeft || '0') || 0 : 0
      const paddingRight = cs ? parseFloat(cs.paddingRight || '0') || 0 : 0
      const clientWidth = body?.clientWidth ?? 0
      const pageStep = computePageStep(clientWidth, columnGap, paddingLeft, paddingRight)
      const total = measurePageCount(
        body?.scrollWidth ?? 0,
        clientWidth,
        columnGap,
        paddingLeft,
        paddingRight
      )
      setPagesInCurrentChapter(total)
      // Record this chapter's measured size so the global page counter
      // can sum across visited chapters. Only update if the value changed
      // to avoid unnecessary renders.
      setChapterPageCounts((prev) =>
        prev[chapterIndex] === total ? prev : { ...prev, [chapterIndex]: total }
      )

      // Resolve any pending cross-chapter navigation request.
      const pending = pendingPageAfterLoadRef.current
      pendingPageAfterLoadRef.current = null
      const desired = pending === 'last' ? total - 1 : (pending ?? pageWithinChapter)
      const applied = applyScrollToPage(doc, iframeWin, desired, total, pageStep)
      if (applied !== pageWithinChapter) setPageWithinChapter(applied)

      // Re-apply the TTS highlight class if we're reading a paragraph in
      // this chapter (the class is wiped when the doc reloads).
      const active = usePlayerStore.getState().activeParagraph
      if (active) {
        const parsed = parseParagraphIndex(active.index)
        if (parsed?.chapter === chapterIndex) {
          setActiveClass(findParagraphElement(doc, parsed.paragraph), true)
        }
      }
    }

    void measureAndScroll()
  }, [applyScrollToPage, chapterIndex, pageWithinChapter])

  // Re-measure on iframe resize so the "current page" stays visible after
  // the user resizes the window. We compute the *current* page from the
  // existing scrollLeft, scale it against the new viewport, and re-apply.
  useEffect(() => {
    const iframe = iframeRef.current
    if (!iframe) return
    let raf = 0
    const observer = new ResizeObserver(() => {
      const doc = iframe.contentDocument
      const win = iframe.contentWindow
      if (!doc || !win || !doc.body) return
      // Batch into a rAF so a flurry of resize events only re-measures once.
      cancelAnimationFrame(raf)
      raf = win.requestAnimationFrame(() => {
        const body = doc.body
        // Re-read column-gap and horizontal padding from computed style on
        // every resize; CSS variables and media queries can change either.
        // The page stride is `clientWidth - paddingLeft - paddingRight +
        // columnGap` — see computePageStep / Azw3View bug notes.
        const cs = win.getComputedStyle(body)
        const columnGap = parseFloat(cs.columnGap || '0') || 0
        const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
        const paddingRight = parseFloat(cs.paddingRight || '0') || 0
        const clientWidth = body.clientWidth
        const pageStep = computePageStep(clientWidth, columnGap, paddingLeft, paddingRight)
        const total = measurePageCount(
          body.scrollWidth,
          clientWidth,
          columnGap,
          paddingLeft,
          paddingRight
        )
        setPagesInCurrentChapter(total)
        // Resize can change a chapter's page count (e.g. window narrows
        // ⇒ more columns). Keep chapterPageCounts in sync so the global
        // counter stays accurate.
        setChapterPageCounts((prev) =>
          prev[chapterIndex] === total ? prev : { ...prev, [chapterIndex]: total }
        )
        applyScrollToPage(doc, win, pageWithinChapter, total, pageStep)
      })
    })
    observer.observe(iframe)
    return () => {
      cancelAnimationFrame(raf)
      observer.disconnect()
    }
  }, [applyScrollToPage, pageWithinChapter, chapterUrl, chapterIndex])

  /** Read the live per-page stride from the iframe's computed style. We read
   *  this fresh on every call instead of caching it because CSS variables and
   *  media queries can change the column-gap or horizontal padding on resize. */
  const readPageStep = useCallback((doc: Document, win: Window): number => {
    const body = doc.body
    if (!body) return 1
    const cs = win.getComputedStyle(body)
    const columnGap = parseFloat(cs.columnGap || '0') || 0
    const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
    const paddingRight = parseFloat(cs.paddingRight || '0') || 0
    return computePageStep(body.clientWidth, columnGap, paddingLeft, paddingRight)
  }, [])

  const goNextPage = useCallback(() => {
    const iframe = iframeRef.current
    const doc = iframe?.contentDocument
    const win = iframe?.contentWindow
    if (pageWithinChapter + 1 < pagesInCurrentChapter) {
      const next = pageWithinChapter + 1
      setPageWithinChapter(next)
      if (doc && win)
        applyScrollToPage(doc, win, next, pagesInCurrentChapter, readPageStep(doc, win))
      return
    }
    // End of chapter — advance to the next, landing on page 0.
    if (chapterIndex < chapterCount - 1) {
      pendingPageAfterLoadRef.current = 0
      setPageWithinChapter(0)
      setChapterIndex(chapterIndex + 1)
    }
  }, [
    applyScrollToPage,
    chapterCount,
    chapterIndex,
    pageWithinChapter,
    pagesInCurrentChapter,
    readPageStep
  ])

  const goPrevPage = useCallback(() => {
    const iframe = iframeRef.current
    const doc = iframe?.contentDocument
    const win = iframe?.contentWindow
    if (pageWithinChapter > 0) {
      const prev = pageWithinChapter - 1
      setPageWithinChapter(prev)
      if (doc && win)
        applyScrollToPage(doc, win, prev, pagesInCurrentChapter, readPageStep(doc, win))
      return
    }
    // Start of chapter — fall back to the previous chapter, landing on its
    // last page. We can't know the last page until the new chapter loads
    // and measures; defer to handleIframeLoad via the pending ref. Also
    // reset pageWithinChapter to 0 *before* the chapter swap so the
    // intermediate state never tries to read a stale page index from the
    // freshly-mounted iframe — mirrors what goNextPage does.
    if (chapterIndex > 0) {
      pendingPageAfterLoadRef.current = 'last'
      setPageWithinChapter(0)
      setChapterIndex(chapterIndex - 1)
    }
  }, [applyScrollToPage, chapterIndex, pageWithinChapter, pagesInCurrentChapter, readPageStep])

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent): void {
      if (e.key === 'ArrowRight') goNextPage()
      else if (e.key === 'ArrowLeft') goPrevPage()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [goNextPage, goPrevPage])

  // Hold the latest measured page count in a ref so the TTS subscription
  // effect below can read it without re-subscribing on every measurement.
  const pagesInCurrentChapterRef = useRef(pagesInCurrentChapter)
  useEffect(() => {
    pagesInCurrentChapterRef.current = pagesInCurrentChapter
  }, [pagesInCurrentChapter])

  // Toggle the TTS highlight class on the matching iframe element as the
  // player advances. Only highlights paragraphs belonging to the current
  // chapter. When the active paragraph is on a different column page,
  // scroll horizontally to bring it into view.
  useEffect(() => {
    const docOf = (): Document | null => iframeRef.current?.contentDocument ?? null
    const winOf = (): Window | null => iframeRef.current?.contentWindow ?? null

    const apply = (raw: string | undefined, on: boolean): void => {
      if (!raw) return
      const parsed = parseParagraphIndex(raw)
      if (parsed?.chapter !== chapterIndex) return
      const doc = docOf()
      const win = winOf()
      const el = findParagraphElement(doc, parsed.paragraph)
      setActiveClass(el, on)

      if (on && el && doc && win) {
        // Bring the active paragraph onto the visible column page. The
        // element's bounding rect is in iframe-viewport coordinates: if
        // its left is negative, it's on an earlier column page; if its
        // right is past the viewport width, it's on a later page.
        const rect = el.getBoundingClientRect()
        const body = doc.body
        if (!body) return
        const viewportWidth = win.innerWidth
        if (rect.left < 0 || rect.right > viewportWidth) {
          // Read pageStep fresh from computed style — it can change on
          // resize, and the TTS subscription is registered once per chapter.
          const cs = win.getComputedStyle(body)
          const columnGap = parseFloat(cs.columnGap || '0') || 0
          const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
          const paddingRight = parseFloat(cs.paddingRight || '0') || 0
          const pageStep = computePageStep(body.clientWidth, columnGap, paddingLeft, paddingRight)
          // Compute the column page that contains this element's left edge.
          // Snap to the column page boundary using pageStep (not viewport
          // width) so we don't accumulate the column-gap error every time
          // TTS scrolls a paragraph into view.
          const elementLeftFromBodyStart = body.scrollLeft + rect.left
          // Read the latest measured page count from a ref so this effect
          // stays subscribed across re-measurements (it's only re-built when
          // the chapter changes).
          const totalPages = pagesInCurrentChapterRef.current
          const targetPage = Math.max(
            0,
            Math.min(totalPages - 1, Math.floor(elementLeftFromBodyStart / pageStep))
          )
          const applied = applyScrollToPage(doc, win, targetPage, totalPages, pageStep)
          setPageWithinChapter((prev) => (prev === applied ? prev : applied))
        }
      }
    }

    const unsubActive = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      (paragraph) => {
        if (paragraph) apply(paragraph.index, true)
      }
    )
    const unsubEnded = usePlayerStore.subscribe(
      (s) => s.endedParagraph,
      (paragraph) => {
        if (paragraph) apply(paragraph.index, false)
      }
    )
    const unsubMove = usePlayerStore.subscribe(
      (s) => s.lastMove,
      (move) => {
        if (move?.from) apply(move.from.index, false)
      }
    )
    return () => {
      unsubActive()
      unsubEnded()
      unsubMove()
    }
  }, [applyScrollToPage, chapterIndex])

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
    const unsubPage = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      (request) => {
        if (request === 'next') goNextPage()
        if (request === 'prev') goPrevPage()
        if (request) usePlayerStore.getState().clearPageRequest()
      }
    )
    return () => {
      unsubPage()
    }
  }, [goNextPage, goPrevPage])

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
        // (Today parseAzw3 returns whole sections so virtualGroupId is only
        //  set for the cover; the dedupe logic is kept defensively in case a
        //  caller pre-paginates sections via `paginateSection`.)
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

  // Whether Next/Prev buttons are on the absolute edge of the book.
  const atFirstPage = chapterIndex === 0 && pageWithinChapter === 0
  const atLastPage =
    chapterIndex === chapterCount - 1 && pageWithinChapter >= pagesInCurrentChapter - 1

  // Global page counter. The displayed "X of Y" is computed across all
  // measured chapters so it doesn't reset at chapter boundaries. Chapters
  // not yet visited contribute 0 to the running totals (we don't pre-
  // measure every chapter on book open). The invariant the e2e test
  // relies on: each forward click increases globalCurrent by exactly 1,
  // including the click that crosses a chapter boundary — which holds
  // because measureAndScroll records chapterPageCounts[K] *before* the
  // user can click past the end of chapter K.
  const globalCurrent = useMemo(() => {
    let sum = 0
    for (let i = 0; i < chapterIndex; i++) {
      sum += chapterPageCounts[i] ?? 0
    }
    return sum + pageWithinChapter + 1
  }, [chapterPageCounts, chapterIndex, pageWithinChapter])
  const globalTotal = useMemo(() => {
    let sum = 0
    for (let i = 0; i < chapterCount; i++) {
      sum += chapterPageCounts[i] ?? 0
    }
    return sum
  }, [chapterPageCounts, chapterCount])

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
            // Force a fresh DOM node per chapter so React tears down and
            // recreates the iframe — guarantees a clean onLoad fires and
            // prevents stale `contentDocument` reads between src change and
            // load completion.
            key={chapterIndex}
            ref={iframeRef}
            src={chapterUrl}
            onLoad={handleIframeLoad}
            className="w-full h-full border-none"
            title={book.title}
            // `allow-scripts` is required so that KF8 books containing inline
            // scripts or `<iframe srcdoc=...>` subframes can finish laying
            // out — without it, real publisher AZW3s render blank ("Blocked
            // script execution in 'about:srcdoc'"). Matches what foliate-js's
            // own paginator uses on its iframes (see paginator.js).
            sandbox="allow-same-origin allow-scripts"
            style={{ background: themeStyle.background }}
          />
        ) : null}
      </div>

      {/* Side-edge navigation arrows — same component the EPUB reader uses
          so the two readers share the same UX. */}
      <NavigationArrows
        onPrev={goPrevPage}
        onNext={goNextPage}
        hidePrev={atFirstPage}
        hideNext={atLastPage}
      />

      {/* Subtle bottom page counter — "X" by default, "X of Y" on hover.
          Values are global page numbers (summed across all measured
          chapters) so the counter advances monotonically across chapter
          boundaries instead of resetting to 1. Until a chapter is
          actually visited it contributes 0 to globalTotal — that's why
          the visible "of N" falls back to '?' before any chapters are
          measured. Tests rely on data-current / data-total so they don't
          depend on hover-state text. */}
      {chapterCount > 0 && (
        <div
          data-testid="azw3-page-counter"
          data-current={globalCurrent}
          data-total={globalTotal || globalCurrent}
          className="group/page"
          style={{
            position: 'fixed',
            bottom: 0,
            left: 0,
            right: 0,
            textAlign: 'center',
            zIndex: 5,
            padding: '8px 0',
            pointerEvents: 'none'
          }}
        >
          <span
            style={{
              fontSize: 12,
              color: themeStyle.color,
              opacity: 0.4
            }}
          >
            <span>{globalCurrent}</span>
            <span className="hidden group-hover/page:inline"> of {globalTotal || '?'}</span>
          </span>
        </div>
      )}

      {isChatting ? (
        <AIChatOrb chatStatus={chatStatus} onClick={() => setChatPanelOpen((prev) => !prev)} />
      ) : null}

      <VoiceChatLauncher />

      <div style={{ display: isChatting ? 'none' : 'contents' }}>
        <TTSControls bookId={book.id.toString()} />
      </div>

      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        title="Navigation"
        bookSyncId={bookSyncId}
        onBookmarkNavigate={(location) => {
          const parsed = parseLocation(location)
          if (parsed.chapter >= 0) {
            // Land on the persisted page within the chapter.
            pendingPageAfterLoadRef.current = parsed.page
            setChapterIndex(parsed.chapter)
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
        bookSyncId={bookSyncId}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />
    </div>
  )
}
