import type React from 'react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useEpubStore } from '@/stores/epubStore'
import { initBookChatSubscription } from '@/stores/initBookChatSubscription'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { updateBookLocation } from '@/lib/api'
import type { Book } from '@/lib/api'
import { NavigationArrows } from '@/components/react-reader/components'
import { themes } from '@/themes/themes'
import { usePlayerStore } from '@/stores/playerStore'
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
import {
  navigationHistoryActor,
  onResumeRequested
} from '@/machines/navigationHistory/navigationHistoryActor'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'
import {
  parseAzw3,
  extractSectionParagraphs,
  stripKindleResourceLinks,
  type FoliateSection
} from './parser'
import { injectReaderStyles } from './reader-styles'
import { findParagraphElement, parseParagraphIndex } from './highlight'
import { computePageStep, formatLocation, measurePageCount, parseLocation } from './pagination'
import { azw3ParagraphToLocation } from './paragraphToLocation'
import { useTtsHighlightReconciler } from '@/hooks/useTtsHighlightReconciler'
import { reconcileAzw3TtsHighlight } from './reconcileTtsHighlight'
import { registerEpubFrame, clearEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

/** Debounce delay before persisting reading location. Page turns fire often
 *  (one per click + per TTS paragraph advance) so we coalesce updates. */
const LOCATION_PERSIST_DEBOUNCE_MS = 500

export default function Azw3View({ book }: { book: Book }): React.JSX.Element {
  const theme = useEpubStore((s) => s.theme)
  const [tocOpen, setTocOpen] = useState(false)
  // Root ref for engagement detector pointer listeners
  const readerRootRef = useRef<HTMLDivElement>(null)
  // Derive the format kind from book.kind so MOBI books opened via the
  // shared Azw3View get the correct PositionDescriptor kind.
  const formatKind = book.kind === 'mobi' ? ('mobi' as const) : ('azw3' as const)

  // Persisted reading position is now `<chapter>:<page>`. parseLocation
  // also accepts the legacy bare-integer form so reopening an existing book
  // doesn't reset the reader to the cover.
  const initialLocation = useMemo(() => {
    if (book.lastParagraph) {
      const resume = azw3ParagraphToLocation(book.lastParagraph)
      if (resume) return resume
    }
    return parseLocation(book.location)
  }, [book.lastParagraph, book.location])
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

  const iframeRef = useRef<HTMLIFrameElement | null>(null)
  // Mirror the iframe element into state so effects that depend on the
  // DOM node (e.g. useTtsHighlightReconciler's `iframe.load` listener)
  // actually re-run when React mounts/unmounts the iframe. A bare ref's
  // `.current` mutation doesn't trigger renders, so consumers would
  // otherwise see `null` forever. See EpubView for the same pattern.
  const [iframeEl, setIframeEl] = useState<HTMLIFrameElement | null>(null)
  const handleIframeRef = useCallback((el: HTMLIFrameElement | null) => {
    iframeRef.current = el
    setIframeEl(el)
  }, [])
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const { requireAuth, AuthDialog } = useRequireAuth()
  const { bookSyncId, bookSyncIdRef } = useBookSyncId(book.id)

  // When navigating backward across a chapter boundary, we want to land on
  // the *last* page of the new chapter — but we can't know how many pages
  // that chapter has until it loads. Stash the request here and have the
  // load handler apply it.
  // Numeric values are explicit page offsets; 'last' means "last page",
  // resolved against the actual measured page count after layout settles.
  const pendingPageAfterLoadRef = useRef<number | 'last' | null>(null)

  const queryClient = useQueryClient()

  // Wire native-menu commands. Same surface as MobiView; AZW3 has no
  // thumbnails or dual-page so those commands are not registered.
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
      }
    }),
    [commonHandlers, chapterIndex, pageWithinChapter, queryClient, bookSyncIdRef]
  )
  useMenuCommands(menuHandlers)

  // Voice chat needs to know which book is active
  const setBookId = useEpubStore((s) => s.setBookId)
  useEffect(() => {
    setBookId(book.id.toString())
  }, [book.id, setBookId])

  // Manage the chat-activation subscription lifecycle — install on mount,
  // tear down on unmount. The shared helper (#237) is the single source of
  // truth for the false→true edge that flips into a startChat call; EpubView
  // and pdfStore use it too so the three reader paths can't drift.
  //
  // Use a component-local ref so rapid navigation doesn't cause the cleanup
  // to wipe the new subscription. Mirrors the pattern at EpubView.tsx:867-875.
  const chatUnsubsRef = useRef<(() => void)[]>([])
  useEffect(() => {
    chatUnsubsRef.current = [initBookChatSubscription(() => book.id)]
    return () => {
      chatUnsubsRef.current.forEach((fn) => fn())
      chatUnsubsRef.current = []
    }
  }, [book.id])

  // Keep the pageCapture EPUB frame registry up-to-date so that pageCapture
  // (Task 5) can grab the active iframe via html-to-image on tool-call demand.
  useEffect(() => {
    if (iframeEl) registerEpubFrame(iframeEl)
    return () => clearEpubFrame()
  }, [iframeEl])

  // Navigation history: lifecycle (BOOK_OPENED / BOOK_CLOSED)
  useEffect(() => {
    navigationHistoryActor.send({
      type: 'BOOK_OPENED',
      bookId: String(book.id),
      initialPosition: { kind: formatKind, cfi: formatLocation(chapterIndex, pageWithinChapter) }
    })
    return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book.id])

  // Navigation history: PAGE_VISITED on every location change
  useEffect(() => {
    const activeParagraph = usePlayerStore.getState().activeParagraph
    const indexStr = activeParagraph?.index
    const paragraphIndex = indexStr != null ? Number(indexStr) : null
    const ttsContext =
      paragraphIndex != null && Number.isFinite(paragraphIndex) ? { paragraphIndex } : null
    navigationHistoryActor.send({
      type: 'PAGE_VISITED',
      position: { kind: formatKind, cfi: formatLocation(chapterIndex, pageWithinChapter) },
      ttsContext
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chapterIndex, pageWithinChapter])

  // Navigation history: RESUME_REQUESTED → navigate to the stored position
  useEffect(() => {
    return onResumeRequested((anchor) => {
      if (anchor.position.kind !== formatKind) return
      const parsed = parseLocation(anchor.position.cfi)
      if (parsed.chapter >= 0) {
        pendingPageAfterLoadRef.current = parsed.page
        setChapterIndex(parsed.chapter)
      }
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Engagement detector (pointer-based dwell tracking)
  useEngagementDetector({ targetRef: readerRootRef, enabled: true })
  // Keyboard back-navigation (Alt+ArrowLeft / mouse button 3)
  useNavigationHistoryKeyboard()

  // Mirror reader state (book title, TOC open, TTS playing) into the native menu.
  useReaderMenuSync({ book, tocOpen })

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
      if (!currentSection.load) return null
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
      const left = clamped * pageStep
      // `behavior: 'instant'` avoids the default smooth-scroll animation
      // (which feels sluggish on chapter switches and would race React).
      body.scrollTo({ left, top: 0, behavior: 'instant' as ScrollBehavior })
      // Fallback for engines that don't implement scrollTo on body.
      body.scrollLeft = left
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
        await doc.fonts.ready
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
      const cs = iframeWin.getComputedStyle(body)
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
      if (!doc || !win) return
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

  // Reconcile the TTS highlight class on every relevant trigger (store
  // change, iframe load, focus return, visibility return). Class
  // management is owned by the reconciler — this hook handles all the
  // event wiring.
  const reconcileTts = useCallback(
    (desired: string | null) => {
      reconcileAzw3TtsHighlight(iframeRef.current?.contentDocument ?? null, chapterIndex, desired)
    },
    [chapterIndex]
  )
  useTtsHighlightReconciler(reconcileTts, iframeEl)

  // Auto-scroll the active paragraph into view when the player advances.
  // This effect is intentionally scoped to activeParagraph store changes only
  // — focus/iframe-load triggers should NOT re-scroll. Class management is
  // owned by the reconciler.
  useEffect(() => {
    const unsub = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      (paragraph) => {
        if (!paragraph) return
        const parsed = parseParagraphIndex(paragraph.index)
        if (parsed?.chapter !== chapterIndex) return
        const doc = iframeRef.current?.contentDocument ?? null
        const win = iframeRef.current?.contentWindow ?? null
        const el = findParagraphElement(doc, parsed.paragraph)
        if (!el || !doc || !win) return
        const rect = el.getBoundingClientRect()
        const body = doc.body
        const viewportWidth = win.innerWidth
        if (rect.left >= 0 && rect.right <= viewportWidth) return
        const cs = win.getComputedStyle(body)
        const columnGap = parseFloat(cs.columnGap || '0') || 0
        const paddingLeft = parseFloat(cs.paddingLeft || '0') || 0
        const paddingRight = parseFloat(cs.paddingRight || '0') || 0
        const pageStep = computePageStep(body.clientWidth, columnGap, paddingLeft, paddingRight)
        const elementLeftFromBodyStart = body.scrollLeft + rect.left
        const totalPages = pagesInCurrentChapterRef.current
        const targetPage = Math.max(
          0,
          Math.min(totalPages - 1, Math.floor(elementLeftFromBodyStart / pageStep))
        )
        const applied = applyScrollToPage(doc, win, targetPage, totalPages, pageStep)
        setPageWithinChapter((prev) => (prev === applied ? prev : applied))
      }
    )
    return unsub
  }, [applyScrollToPage, chapterIndex])

  // Publish paragraphs to playerStore for TTS. Current chapter immediately,
  // next/prev debounced to avoid wasted work on rapid chapter flips.
  // Note: noUncheckedIndexedAccess is off, so sections[idx] looks typed as
  // FoliateSection even when out-of-range; check via Array.prototype.at to
  // get a real `| undefined` result and short-circuit before parse completes.
  useChapterParagraphPrefetch({
    chapterIndex,
    chapterCount,
    indexPrefix: 'azw3',
    fetchCurrent: async (idx) => {
      const section = sections.at(idx)
      return section ? extractSectionParagraphs(section) : []
    },
    fetchAt: async (idx) => {
      const section = sections.at(idx)
      return section ? extractSectionParagraphs(section) : []
    }
  })

  // Handle page-turn events from Player (TTS exhausted current chapter).
  // goNextPage / goPrevPage close over pendingPageAfterLoadRef; the hook
  // accesses these callbacks via internal refs so the subscription is not
  // re-created on every re-render.
  usePageRequestSubscription({
    onNext: goNextPage,
    onPrev: goPrevPage,
    autoClear: true
  })

  // Generate embeddings on first open (for AI chat). The shared hook owns
  // the hasIndexedBookData check + indexBook dispatch + run-once guard;
  // we just build the AZW3-flavoured PageDataInsertable list, including
  // the virtualGroupId dedup that keeps virtual sections from emitting
  // 87 near-duplicate entries per source doc.
  useBookEmbeddings({
    bookId: book.id,
    ready: chapterCount > 0,
    buildPageData: async () => {
      const allPageData: PageDataInsertable[] = []
      // Virtual sections (paginateSection) all share a single source doc, so
      // emit a single combined entry per virtualGroupId instead of indexing
      // 87 near-duplicate per-page slices. This both saves time and keeps
      // the indexing pipeline aligned with the original section semantics.
      // (Today parseAzw3 returns whole sections so virtualGroupId is only
      //  set for the cover; the dedupe logic is kept defensively in case a
      //  caller pre-paginates sections via `paginateSection`.)
      // Plan extraction tasks linearly (no async work here) so we know the
      // section index ranges that each output entry covers. Then run all
      // per-section paragraph extractions in parallel — they don't share
      // mutable state and order is reconstructed from the planned indices.
      type Task = { kind: 'group'; pageNumber: number; id: number; sectionIdxs: number[] }
      const tasks: Task[] = []
      const seenGroups = new Set<string>()
      for (let i = 0; i < sections.length; i++) {
        const section = sections[i]
        if (section.virtualGroupId) {
          if (seenGroups.has(section.virtualGroupId)) continue
          seenGroups.add(section.virtualGroupId)
          const sectionIdxs: number[] = []
          for (let j = i; j < sections.length; j++) {
            if (sections[j].virtualGroupId !== section.virtualGroupId) break
            sectionIdxs.push(j)
          }
          tasks.push({
            kind: 'group',
            pageNumber: i + 1,
            id: stringToNumberID(`${book.id}-azw3-${section.virtualGroupId}`),
            sectionIdxs
          })
          continue
        }
        tasks.push({
          kind: 'group',
          pageNumber: i + 1,
          id: stringToNumberID(`${book.id}-azw3-${i}`),
          sectionIdxs: [i]
        })
      }

      // Extract paragraphs for every unique section once, in parallel.
      const uniqueSectionIdxs = Array.from(new Set(tasks.flatMap((t) => t.sectionIdxs)))
      const extractedEntries = await Promise.all(
        uniqueSectionIdxs.map(async (idx) => {
          const texts = await extractSectionParagraphs(sections[idx])
          return [idx, texts] as const
        })
      )
      const extracted = new Map<number, string[]>(extractedEntries)

      for (const task of tasks) {
        const combined = task.sectionIdxs
          .flatMap((idx) => extracted.get(idx) ?? [])
          .join('\n')
          .trim()
        if (combined.length > 0) {
          allPageData.push({
            id: task.id,
            pageNumber: task.pageNumber,
            bookId: book.id,
            data: combined
          })
        }
      }
      return allPageData
    }
  })

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
    <div ref={readerRootRef} className="relative h-full">
      <div
        className="relative h-screen flex flex-col"
        style={{ background: themeStyle.background }}
      >
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
              ref={handleIframeRef}
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

        {/* AI chat orb, voice chat launcher, and TTS controls */}
        <ReaderOverlayControls
          bookId={book.id.toString()}
          chatPanelOpen={chatPanelOpen}
          onChatOrbClick={() => setChatPanelOpen((prev) => !prev)}
        />

        <ReaderTOC
          open={tocOpen}
          onOpenChange={setTocOpen}
          title="Navigation"
          bookSyncId={bookSyncId}
          onBookmarkNavigate={(location) => {
            const parsed = parseLocation(location)
            if (parsed.chapter >= 0) {
              // Dispatch a JUMP_REQUESTED before navigating so the history
              // machine records the "from" anchor and can offer resume later.
              const currentPos = formatLocation(chapterIndex, pageWithinChapter)
              const activeParagraph = usePlayerStore.getState().activeParagraph
              const indexStr = activeParagraph?.index
              const paragraphIndex = indexStr != null ? Number(indexStr) : null
              const fromTts =
                paragraphIndex != null && Number.isFinite(paragraphIndex)
                  ? { paragraphIndex }
                  : null
              navigationHistoryActor.send({
                type: 'JUMP_REQUESTED',
                from: { kind: formatKind, cfi: currentPos },
                fromTts,
                to: { kind: formatKind, cfi: location },
                source: 'bookmark',
                fromLabel: 'previous spot'
              })
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
      <NavigationHistoryFooter />
    </div>
  )
}
