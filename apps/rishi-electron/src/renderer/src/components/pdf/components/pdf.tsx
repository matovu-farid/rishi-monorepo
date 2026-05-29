import type React from 'react'
import { useEffect, useState, useMemo, useRef, useCallback } from 'react'
import { ThemeType } from '@/themes/common'
import Loader from '@/components/Loader'
import AIChatOrb from '../../chat/AIChatOrb'
import VoiceChatLauncher from '../../chat/VoiceChatLauncher'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { Outline, pdfjs } from 'react-pdf'
// AnnotationLayer (rendered by <Page>) reads `pdf` + `linkService` from
// react-pdf's DocumentContext. We bypass <Document> so we provide the
// context ourselves. These are internal paths but stable: react-pdf's
// package.json exposes `./*` mapped to its dist tree.
import DocumentContext from 'react-pdf/dist/DocumentContext.js'
import LinkService from 'react-pdf/dist/LinkService.js'
import type { DocumentInitParameters } from 'pdfjs-dist/types/src/display/api'
import { getCachedPdf, setCachedPdf } from '@/services/reader-cache/pdf-cache'
import { usePlayerStore } from '@/stores/playerStore'
import { nextPage, previousPage } from '../utils/pageControls'
import {
  navigationHistoryActor,
  onResumeRequested
} from '@/machines/navigationHistory/navigationHistoryActor'
import type { PositionDescriptor } from '@/machines/navigationHistory/types'
import { useEngagementDetector } from '@/hooks/useEngagementDetector'
import { useNavigationHistoryKeyboard } from '@/hooks/useNavigationHistoryKeyboard'
import { NavigationHistoryFooter } from '@/components/navigation-history/NavigationHistoryFooter'

import { cn } from '@/lib/utils'

// Import required CSS for text and annotation layers
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

import { usePdfStore } from '@/stores/pdfStore'
import { ThumbnailSidebar } from './thumbnail-sidebar'
import TTSControls from '@/components/tts/TTSControls'
import { pdfViewActor, type PdfViewInput, type PdfViewSnapshot } from '@/actors/pdfViewActor'
import { usePlayerMachine } from '@/hooks/usePlayerMachine'
import type { TextItem } from 'react-pdf'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { useUpdateCoverIMage } from '../hooks/useUpdateCoverIMage'
import { useScrolling } from '../hooks/useScrolling'
import { usePdfNavigation } from '../hooks/usePdfNavigation'
import { PageComponent } from './pdf-page'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import { useVirualization } from '../hooks/useVirualization'
import { PAGE_GAP } from '../utils/constants'
import { parsePdfLocation } from '@/lib/pdfLocation'
import type { ViewportLike } from '@/modules/pdf-locator'
import { pdfParagraphToPageNumber } from '@/components/pdf/utils/pdfParagraphToPageNumber'
import { Effect, Fiber } from 'effect'
import { indexBookProgram } from '@/services/indexing/index-program'
import { loadPdfDocument, extractPageParagraphs } from '@/services/indexing/text-extraction'
import {
  buildFooterMask,
  MIN_PAGES_FOR_DETECTION,
  type PageScanInput
} from '../utils/buildFooterMask'
import { findRepeatingPageSuffix } from '../utils/findRepeatingPageSuffix'
import { usePrefsStore } from '@/stores/prefsStore'
import { useIndexingStore } from '@/stores/indexingStore'
import { usePdfReader } from '@/hooks/usePdfReader'
import type { Book } from '@/lib/api'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useChatStore } from '@/stores/chatStore'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { SelectionPopover } from '@/components/highlights/SelectionPopover'
import { HighlightActionPopover } from '@/components/highlights/HighlightActionPopover'
import { NoteEditor } from '@/components/highlights/NoteEditor'
import { usePdfTextSelection } from '@/hooks/usePdfTextSelection'
import { usePdfHighlights } from '@/hooks/usePdfHighlights'
import { usePdfReadAloudFromSelection } from '@/hooks/usePdfReadAloudFromSelection'
import { useUndoableHighlightShortcut } from '@/hooks/useUndoableHighlightShortcut'
import { applyHighlightWithUndoPdf, deleteHighlightByIdWithUndo } from '@/modules/highlight-actions'
import {
  updateHighlightColor,
  type HighlightRow,
  type PdfLocator
} from '@/modules/highlight-storage'
import type { PDFPageProxy } from 'pdfjs-dist'
import type { HighlightColor } from '@/types/highlight'
import type { MouseEvent as ReactMouseEvent } from 'react'

// Configure PDF.js worker
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  'pdfjs-dist/build/pdf.worker.min.mjs',
  import.meta.url
).toString()

export function PdfView({
  book,
  filepath: _filepath
}: {
  filepath: string
  book: Book
}): React.JSX.Element {
  const [theme] = useState<ThemeType>(ThemeType.White)
  const [tocOpen, setTocOpen] = useState(false)
  const [bookSyncId, setBookSyncId] = useState<string>('')
  const [chatPanelOpen, setChatPanelOpen] = useState(false)
  const thumbOpen = usePdfStore((s) => s.thumbnailSidebarOpen)
  const setThumbOpen = usePdfStore((s) => s.setThumbnailSidebarOpen)
  const setPdfDocProxy = usePdfStore((s) => s.setPdfDocumentProxy)

  const { requireAuth, AuthDialog } = useRequireAuth()
  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const queryClient = useQueryClient()

  const scrollContainerRef = useRef<HTMLDivElement>(null)
  const [selectionPopover, setSelectionPopover] = useState<{
    locator: PdfLocator
    text: string
    anchorPos: { x: number; y: number }
  } | null>(null)
  const [inlinePopover, setInlinePopover] = useState<{
    rowId: string
    position: { x: number; y: number }
    currentColor: HighlightColor
  } | null>(null)
  const [editingNoteRow, setEditingNoteRow] = useState<HighlightRow | null>(null)
  const pageInfoRef = useRef<Map<number, { pageEl: HTMLElement; page: PDFPageProxy }>>(new Map())
  const { setLastUndoable } = useUndoableHighlightShortcut()
  // Highlights are keyed on the IPC-fetched bookSyncId (NOT the book.syncId
  // prop, which the router may not populate). When that state arrives, the
  // hook loads + filters PDF rows; subsequent updates flow through setHighlights.
  const { highlights, setHighlights, refresh: refreshHighlights } = usePdfHighlights(bookSyncId)
  // useRequireAuth narrows the feature key to PremiumFeature; the read-aloud
  // hook accepts a plain string for testability. Same widening pattern is used
  // in EpubView's menu-handler wiring.
  usePdfReadAloudFromSelection({
    requireAuth: requireAuth as (feature: string, action: () => void) => void
  })

  // Memoize the selection-hook callbacks so usePdfTextSelection's effect
  // doesn't rebind document/container listeners on every PdfView render. The
  // hook now lists these in its dep array (rather than reading from a
  // render-time ref), so unstable identities here would cause the listeners
  // to detach and reattach on every parent render — wasteful, plus the
  // mouseup listener is briefly missing in the window between cleanup and
  // re-attach.
  const getSelectionPageElement = useCallback(
    (n: number) => pageInfoRef.current.get(n)?.pageEl ?? null,
    []
  )
  const getSelectionViewport = useCallback((n: number): ViewportLike | null => {
    const info = pageInfoRef.current.get(n)
    if (!info) return null
    const scale = info.pageEl.getBoundingClientRect().width / info.page.view[2]
    // pdfjs-dist types return `any[]` from convertToViewportPoint; cast via
    // unknown to the structural ViewportLike which expects [number, number].
    return info.page.getViewport({
      scale
    }) as unknown as ViewportLike
  }, [])
  const handleSelectionSelect = useCallback(
    (sel: { locator: PdfLocator; text: string; anchorPos: { x: number; y: number } }) =>
      setSelectionPopover({ locator: sel.locator, text: sel.text, anchorPos: sel.anchorPos }),
    []
  )
  const handleSelectionClear = useCallback(() => setSelectionPopover(null), [])
  usePdfTextSelection({
    containerRef: scrollContainerRef,
    getPageElement: getSelectionPageElement,
    getViewport: getSelectionViewport,
    onSelect: handleSelectionSelect,
    onClear: handleSelectionClear
  })

  useScrolling(scrollContainerRef)

  // Create the player actor here, co-located with the PDF page controls and
  // pdfStore, so we can wire pdfViewActor with the per-format adapters:
  // next/prev call the existing pageControls, goTo writes pdfStore directly,
  // and subscribe/getSnapshot read the live page + paragraphs the same way
  // the old seed-from-pdfStore branch did inside usePlayerMachine. Empty
  // deps keep the adapter stable for the lifetime of the PDF view — book
  // swaps remount via `key={book.id}` on the parent route, so a stale book
  // can't leak through.
  const viewInput = useMemo<PdfViewInput>(() => {
    const toSnapshot = (): PdfViewSnapshot => {
      const s = usePdfStore.getState()
      const data = s.pageNumberToPageData[s.pageNumber]
      // dataReady flag lets pdfViewActor distinguish "still extracting"
      // (transient, defer) from "extracted but no text" (image-only, fail
      // nav). Without it, auto-advance fires NAV_NO_PROGRESS during the
      // ~50-500ms window after the virtualizer scrolls to the next page
      // and before pdf.js's worker delivers its TextContent — and the
      // player drops to stopped instead of resuming on paragraph 0.
      if (!data) return { page: s.pageNumber, paragraphs: [], dataReady: false }
      const paragraphs = data.items
        .filter((item): item is TextItem => 'str' in item && item.str.trim() !== '')
        .map((item, idx) => ({
          index: `pdf-${s.pageNumber}-${idx}`,
          text: item.str
        }))
      return { page: s.pageNumber, paragraphs, dataReady: true }
    }
    return {
      next: () => nextPage(),
      prev: () => previousPage(),
      goTo: (page: number) => usePdfStore.setState({ pageNumber: page }),
      subscribe: (cb) =>
        usePdfStore.subscribe(
          (s) => ({ page: s.pageNumber, data: s.pageNumberToPageData[s.pageNumber] }),
          () => cb(toSnapshot())
        ),
      getSnapshot: toSnapshot
    }
  }, [])
  usePlayerMachine(book.id.toString(), { viewLogic: pdfViewActor, viewInput })

  useUpdateCoverIMage(book)
  // Ref for the scrollable container

  const resetParaphState = usePdfStore((s) => s.resetParagraphState)

  useEffect(() => {
    return () => {
      resetParaphState()
      setThumbOpen(false)
      setPdfDocProxy(null)
    }
  }, [resetParaphState, setThumbOpen, setPdfDocProxy])

  // Scoped playerStore subscriptions for PDF highlighting.
  // These must be inside the component lifecycle so they are cleaned up when
  // navigating away from the PDF reader — otherwise they leak across formats.
  //
  // Empty deps `[]` is intentional: PdfView is mounted with `key={book.id}` in
  // books.$id.lazy.tsx, so a book switch triggers a full remount.
  // `usePdfStore`/`usePlayerStore` reads use `.getState()` or subscriptions
  // which always see the latest values. Page navigation is driven by the view
  // actor (NAVIGATE_NEXT/PREV via the viewInput adapter above), not by this
  // subscription.
  useEffect(() => {
    const unsubActive = usePlayerStore.subscribe(
      (s) => ({ active: s.activeParagraph, resume: s.lastPlayedParagraphIndex }),
      ({ active, resume }) => {
        if (active) {
          usePdfStore.getState().setIsHighlighting(true)
          usePdfStore.getState().setHighlightedParagraphIndex(active.index)
        } else if (resume) {
          usePdfStore.getState().setHighlightedParagraphIndex(resume)
        }
      },
      { equalityFn: (a, b) => a.active === b.active && a.resume === b.resume }
    )

    {
      const initial = usePlayerStore.getState()
      if (!initial.activeParagraph && initial.lastPlayedParagraphIndex) {
        usePdfStore.getState().setHighlightedParagraphIndex(initial.lastPlayedParagraphIndex)
      }
    }

    const unsubState = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        usePdfStore.getState().setIsHighlighting(state === 'playing')
      }
    )

    return () => {
      unsubActive()
      unsubState()
    }
  }, [])

  // Fetch the book sync_id via Electron IPC database query
  useEffect(() => {
    void window.electron
      .booksGetSyncId(book.id)
      .then((syncId) => {
        if (syncId) setBookSyncId(syncId)
      })
      .catch((err: unknown) => {
        console.error('Failed to fetch book sync_id:', err)
      })
  }, [book.id])

  // Publish bookmarks to the native-menu context whenever the sync id is
  // first known. Subsequent edits (addBookmark) re-publish from the menu
  // handler.
  useEffect(() => {
    if (!bookSyncId) return
    void publishBookmarksToMenu(bookSyncId)
  }, [bookSyncId])

  // Publish the book title to main so the Window menu's open-books submenu
  // shows the real title (not whatever the DB had at window-creation time).
  useEffect(() => {
    const e = (window as unknown as { electron: { send(c: string, p: unknown): void } }).electron
    e.send('window:setBookTitle', { bookId: book.id, title: book.title })
  }, [book.id, book.title])

  // Mirror TTS play state into the menu so the Reader > Read Aloud label
  // flips to "Stop Read Aloud" while playback is active.
  useEffect(() => {
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    const unsub = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        e.setMenuContext({ isReading: state === 'playing' })
      }
    )
    // Initial publish so the menu reflects the current state on mount.
    e.setMenuContext({ isReading: usePlayerStore.getState().playingState === 'playing' })
    return unsub
  }, [])

  // Configure PDF.js options with CDN fallback for better font and image support
  const pdfOptions = useMemo<DocumentInitParameters>(
    () => ({
      cMapPacked: true,

      verbosity: 0
    }),
    []
  )
  const { isDualPage, pdfWidth, pdfHeight, dualPageWidth, isFullscreen } =
    usePdfNavigation(scrollContainerRef)

  // Setup View submenu in the app menu for PDF view
  const isDualPageRef = useRef(isDualPage)

  // Keep ref in sync with current value
  useEffect(() => {
    isDualPageRef.current = isDualPage
  }, [isDualPage])

  // Mirror reader UI state into the native menu context so the View menu's
  // checkmarks (Show TOC, Show Thumbnails, Dual Page) flip with the actual
  // reader state — not whatever value happened to be in the menu when the
  // window was last focused.
  useEffect(() => {
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    e.setMenuContext({ tocOpen, thumbsOpen: thumbOpen, dualPage: isDualPage })
  }, [tocOpen, thumbOpen, isDualPage])

  // Mount the paragraph atoms so they're available for the player control

  function getTextColor() {
    switch (theme) {
      case ThemeType.White:
        return 'text-black hover:bg-black/10 hover:text-black'
      case ThemeType.Dark:
        return 'text-white hover:bg-white/10 hover:text-white'
      default:
        return 'text-black hover:bg-black/10 hover:text-black'
    }
  }

  const pageCount = usePdfStore((s) => s.pageCount)
  const setPageCount = usePdfStore((s) => s.setPageCount)

  const pageWidth = isDualPage ? dualPageWidth : pdfWidth
  // Stable string for memoized PageComponent — `book.id.toString()` returns a
  // new primitive each render which is equal by value but we keep this memo'd
  // for clarity and to avoid recomputation.
  const bookIdStr = useMemo(() => book.id.toString(), [book.id])

  const { virtualizer, virtualItems, pageRefs, handlePageRendered } = useVirualization(
    scrollContainerRef,
    book
  )

  // Stable ref-setter for each virtualized page item. Defined as a
  // useCallback outside the JSX so React Compiler sees a single, stable
  // callback identity rather than an inline arrow created during render
  // (which the compiler conservatively flags as a render-time ref access
  // when the closure touches `pageRefs.current` / virtualizer internals).
  // The setter itself runs at commit time when React attaches the node,
  // not during render — so the `.current` writes are safe.
  //
  // The index is read from the node's `data-index` attribute rather than
  // captured via closure, so a single callback identity works for every
  // virtualized item — without that, returning a fresh per-index closure
  // each render would cause React to fire the ref callback on every
  // render (detach + re-attach the DOM node).
  //
  // Returns a React 19 ref-callback cleanup so the entry is removed from
  // pageRefs when the virtualizer unmounts the item.
  const setPageNodeRef = useCallback(
    (node: HTMLDivElement): (() => void) => {
      const indexAttr = node.dataset.index
      const index = indexAttr ? Number(indexAttr) : NaN
      if (!Number.isNaN(index)) {
        pageRefs.current.set(index, node)
      }
      virtualizer.measureElement(node)
      return () => {
        if (!Number.isNaN(index)) {
          pageRefs.current.delete(index)
        }
      }
    },
    [pageRefs, virtualizer]
  )

  // pdfReader owns navigation + persistence via xstate. Replaces the old
  // useCurrentPageNumber tangle of useEffects (initial-seek lockout, debounced
  // save with unmount-flush, paragraph publishing) with one explicit machine
  // whose state can't be stomped from outside.
  const pdfReader = usePdfReader(book, virtualizer, scrollContainerRef)

  // Ref for the reader root — used by useEngagementDetector to attach pointer listeners.
  const readerRootRef = useRef<HTMLDivElement>(null)

  // Read current PDF page reactively from pdfStore (the machine mirrors it there).
  // usePdfReader does NOT expose currentPage/currentOffset directly on its API.
  const currentPdfPage = usePdfStore((s) => s.pageNumber)

  // Read activeParagraph reactively for TTS context dispatch.
  const activeParagraph = usePlayerStore((s) => s.activeParagraph)

  // Helper: build a TtsContext from the current activeParagraph.
  // ParagraphWithIndex.index is a string; TtsContext.paragraphIndex is a number.
  const ttsContext =
    activeParagraph != null ? { paragraphIndex: Number(activeParagraph.index) } : null

  // Navigation history: lifecycle events (BOOK_OPENED / BOOK_CLOSED)
  useEffect(() => {
    navigationHistoryActor.send({
      type: 'BOOK_OPENED',
      bookId: String(book.id),
      initialPosition: {
        kind: 'pdf',
        page: usePdfStore.getState().pageNumber || 1,
        offset: 0
      }
    })
    return () => navigationHistoryActor.send({ type: 'BOOK_CLOSED' })
    // Re-fire if book.id changes (component is mounted with key={book.id} so this
    // normally only fires once per mount, but kept explicit for correctness).
  }, [book.id])

  // Navigation history: PAGE_VISITED on every page change
  useEffect(() => {
    if (currentPdfPage <= 0) return
    navigationHistoryActor.send({
      type: 'PAGE_VISITED',
      position: { kind: 'pdf', page: currentPdfPage, offset: 0 },
      ttsContext
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentPdfPage])

  // Navigation history: RESUME_REQUESTED → seek to saved position
  useEffect(() => {
    return onResumeRequested((anchor) => {
      if (anchor.position.kind !== 'pdf') return
      pdfReader.seekTo(anchor.position.page)
    })
  }, [pdfReader])

  // Engagement + keyboard navigation hooks
  useEngagementDetector({ targetRef: readerRootRef, enabled: true })
  useNavigationHistoryKeyboard()

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. Setters from useState and
  // store actions read via getState() are stable identities, so this memo
  // only rebinds when `requireAuth`/`bookSyncId`/`book.id` change.
  const menuHandlers = useMemo(
    () => ({
      toggleTOC: () => setTocOpen((v) => !v),
      toggleThumbnails: () => setThumbOpen((v) => !v),
      toggleDualPage: () => usePdfStore.setState((s) => ({ isDualPage: !s.isDualPage })),
      addBookmark: () => {
        if (!bookSyncId) return
        const pageNum = usePdfStore.getState().pageNumber
        void toggleBookmark({
          bookSyncId,
          location: String(pageNum),
          label: `Page ${pageNum}`
        })
          .then(async () => {
            void queryClient.invalidateQueries({ queryKey: ['bookmarks', bookSyncId] })
            await publishBookmarksToMenu(bookSyncId)
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
      openChat: () => requireAuth('ai-chat', () => setChatPanelOpen((v) => !v)),
      voiceChat: () => {
        const { isChatting: chatting, setIsChatting } = useChatStore.getState()
        if (chatting) setIsChatting(false)
        else requireAuth('voice-input', () => setIsChatting(true))
      }
    }),
    [requireAuth, bookSyncId, queryClient, setThumbOpen]
  )
  useMenuCommands(menuHandlers)

  // Stable callbacks so the memos that consume them (documentContextValue,
  // ReaderTOC props) keep stable identity across renders.
  const onItemClick = useCallback(
    ({ pageNumber: itemPageNumber }: { pageNumber: number }) => {
      const fromPage = usePdfStore.getState().pageNumber
      const fromPosition: PositionDescriptor = { kind: 'pdf', page: fromPage, offset: 0 }
      const fromTts =
        usePlayerStore.getState().activeParagraph != null
          ? { paragraphIndex: Number(usePlayerStore.getState().activeParagraph!.index) }
          : null
      navigationHistoryActor.send({
        type: 'JUMP_REQUESTED',
        from: fromPosition,
        fromTts,
        to: { kind: 'pdf', page: itemPageNumber, offset: 0 },
        source: 'toc',
        fromLabel: `p. ${fromPage}`
      })
      pdfReader.seekTo(itemPageNumber)
      setTocOpen(false)
    },
    [pdfReader]
  )

  const onThumbnailNavigate = useCallback(
    (pageNumber: number) => {
      pdfReader.seekTo(pageNumber)
    },
    [pdfReader]
  )

  // PDF loading — bypasses react-pdf's <Document> so we own the proxy
  // lifecycle. The warm-restore cache (services/reader-cache/pdf-cache)
  // holds up to 3 parsed proxies keyed by bookId; reopening a recently-
  // viewed book skips the ~800ms parse entirely. The cache also owns
  // proxy.destroy() so we never call it from here.
  //
  // The lazy initializers read the cache synchronously so a cache hit
  // renders with the proxy on the very first paint — no loader flash.
  const [pdfProxy, setPdfProxy] = useState<PDFDocumentProxy | null>(
    () => getCachedPdf(book.id)?.document ?? null
  )
  const [pdfBytes, setPdfBytes] = useState<Uint8Array | null>(
    () => getCachedPdf(book.id)?.bytes ?? null
  )
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    // Use an object so the inner async closure observes mutations made by
    // the cleanup. A primitive `let` would be narrowed by TS to its initial
    // value within the closure, making the post-await guards appear dead.
    const state: { cancelled: boolean } = { cancelled: false }

    if (getCachedPdf(book.id)) {
      // Cache hit — state already initialized from cache by useState. No
      // need to clear loadError synchronously: this branch returns before
      // any new error could be produced for this book.
      return () => {
        state.cancelled = true
      }
    }

    // Read state.cancelled through a getter so that each call re-reads the
    // mutable property — TS narrows direct reads to `false` after the first
    // check, hiding the post-await re-checks from `no-unnecessary-condition`.
    const isCancelled = (): boolean => state.cancelled

    void (async () => {
      try {
        const data: unknown = await window.electron.readFile(book.filepath)
        if (isCancelled()) return
        let bytes: Uint8Array
        if (data instanceof ArrayBuffer) {
          bytes = new Uint8Array(data)
        } else if (ArrayBuffer.isView(data)) {
          // Why: ArrayBuffer.isView narrows to ArrayBufferView in TS but the
          // structural fields we read live on every TypedArray + DataView.
          const view = data
          bytes = new Uint8Array(view.buffer, view.byteOffset, view.byteLength)
        } else {
          // Some serialization paths flatten typed arrays to {0: n, 1: n, ...}.
          // Cast through the structural shape we expect rather than `any`.
          bytes = new Uint8Array(Object.values(data as Record<string, number>))
        }
        // pdfjs detaches the buffer it parses; pass a clone so `bytes` stays
        // intact for indexing and re-parse.
        const loadingTask = pdfjs.getDocument({ data: bytes.slice(), ...pdfOptions })
        const proxy = await loadingTask.promise
        if (isCancelled()) {
          void proxy.destroy()
          return
        }
        setCachedPdf(book.id, proxy, bytes)
        setPdfProxy(proxy)
        setPdfBytes(bytes)
        // Clear any stale error from a previous attempt only after a fresh
        // successful load. Avoids a synchronous setState-in-effect cascade
        // (the effect would always fire setLoadError(null) on every run,
        // including the cache-hit fast path).
        setLoadError((prev) => (prev === null ? prev : null))
      } catch (err) {
        if (!isCancelled()) {
          console.error('[pdf] load failed:', err)
          setLoadError(err instanceof Error ? err.message : String(err))
        }
      }
    })()

    return () => {
      state.cancelled = true
    }
  }, [book.id, book.filepath, pdfOptions])

  // Hydrate the singleton pdfStore + the reader machine whenever the proxy
  // resolves (from cache or fresh parse). Kept separate from the loader so
  // a cache hit fires synchronously on mount.
  useEffect(() => {
    if (!pdfProxy) return
    setPageCount(pdfProxy.numPages)
    setPdfDocProxy(pdfProxy)
    pdfReader.sendDocLoaded(pdfProxy.numPages)
    // pdfReader is a hook result — its identity changes per render. Listing
    // it here would re-fire on every render; we only want this to run when
    // the proxy actually changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pdfProxy, setPageCount, setPdfDocProxy])

  // Stand-in for the DocumentContext that <Document> would normally provide.
  // AnnotationLayer (inside <Page>) reads `pdf` + `linkService` from this
  // context and throws an invariant if either is missing. We instantiate a
  // single LinkService and bind it to the current proxy whenever it changes.
  // registerPage/unregisterPage are no-ops — react-pdf only uses them for
  // internal Outline auto-scroll, which we drive ourselves via pdfReader.
  //
  // Using lazy useState (not useRef) so the LinkService instance is a
  // first-class render value — the React Compiler forbids reading
  // `ref.current` during render, and `documentContextValue` (a memo
  // consumed by JSX below) needs access to it on the render path.
  const [linkService] = useState<LinkService>(() => new LinkService())
  useEffect(() => {
    if (pdfProxy) linkService.setDocument(pdfProxy)
  }, [pdfProxy, linkService])

  const documentContextValue = useMemo(
    () =>
      pdfProxy
        ? {
            pdf: pdfProxy,
            linkService,
            onItemClick,
            registerPage: () => {},
            unregisterPage: () => {}
          }
        : null,
    [pdfProxy, linkService, onItemClick]
  )

  // Background indexing: extract per-page text and ship to the embedding/vector
  // pipeline so chat/RAG works for this book. Runs as an Effect fiber with
  // bounded concurrency; interrupted when the book unmounts.
  useEffect(() => {
    if (!pdfBytes) return

    // Use an object so the inner async closure observes mutations made by
    // the cleanup. A primitive `let` would be narrowed by TS to its initial
    // value within the closure, making the post-await guards appear dead.
    const state: { cancelled: boolean } = { cancelled: false }
    let fiber: Fiber.RuntimeFiber<void, Error> | null = null
    // Hold the proxy in a single-slot box rather than a `let` that the
    // async run reassigns. Both the async body and the cleanup function
    // close over this object, so the cleanup always sees the current value
    // without a race against `await`-deferred reassignment.
    const docHolder: { current: Awaited<ReturnType<typeof loadPdfDocument>> | null } = {
      current: null
    }

    // Read state.cancelled through a getter so that each call re-reads the
    // mutable property — TS narrows direct reads to `false` after the first
    // check, hiding the post-await re-checks from `no-unnecessary-condition`.
    const isCancelled = (): boolean => state.cancelled

    const run = async (): Promise<void> => {
      try {
        // Indexing keeps its own throwaway proxy — it walks every page and
        // can run after the visible reader unmounts. Sharing the cached
        // proxy would risk indexing destroying it on its own cleanup.
        const loadedDoc = await loadPdfDocument(pdfBytes)
        if (isCancelled()) {
          await loadedDoc.destroy()
          return
        }
        docHolder.current = loadedDoc

        const numPages = loadedDoc.numPages

        // Pages already in chunk_data don't need to be re-extracted or
        // re-embedded. Fetch them once upfront and skip them in the schedule.
        const indexedPages = await window.electron.getIndexedPageNumbers(book.id)
        if (isCancelled()) return
        const skipPages = new Set(indexedPages)

        // Footer-detection pass (#142): walk every page, sample TextContent
        // for the bottom band, build the FooterMask. Skipped when the pref
        // is off OR the book is too short for the heuristic to be reliable.
        // Mask lives in-memory only; clearing/toggling the pref doesn't
        // re-scan — selector consults the pref at read time.
        if (!usePrefsStore.getState().pdfFooterDetection || numPages < MIN_PAGES_FOR_DETECTION) {
          usePdfStore.getState().setFooterMask(book.id, new Map())
        } else {
          const scans: PageScanInput[] = []
          for (let n = 1; n <= numPages; n++) {
            if (isCancelled()) return
            const page = await loadedDoc.getPage(n)
            try {
              const content = await page.getTextContent()
              const view = page.view
              const viewportHeight = view[3] - view[1]
              scans.push({ pageNumber: n, content, viewportHeight })
            } finally {
              page.cleanup()
            }
          }
          if (isCancelled()) return
          const mask = buildFooterMask(scans)
          const suffixMask = findRepeatingPageSuffix(scans)
          for (const [pageNumber, itemSet] of suffixMask) {
            let target = mask.get(pageNumber)
            if (!target) {
              target = new Set<number>()
              mask.set(pageNumber, target)
            }
            for (const ix of itemSet) target.add(ix)
          }
          usePdfStore.getState().setFooterMask(book.id, mask)
        }

        // Short-circuit if the whole book is already indexed.
        if (skipPages.size >= numPages) {
          useIndexingStore.getState().start(book.id, numPages)
          useIndexingStore.getState().finish(book.id)
          return
        }

        // Seed the progress store: total = numPages, done = pages already
        // indexed so the UI reflects existing work immediately.
        useIndexingStore.getState().start(book.id, numPages)
        for (let i = 0; i < skipPages.size; i++) {
          useIndexingStore.getState().advance(book.id)
        }

        // Index the page the user is opening on first so chat/RAG works for
        // their current location immediately. book.location is a string
        // holding the saved page number (or "page:offset"); falls back to 1
        // on fresh opens.
        const resumePage = book.lastParagraph ? pdfParagraphToPageNumber(book.lastParagraph) : null
        const startPage = resumePage ?? (parsePdfLocation(book.location).page || 1)

        fiber = Effect.runFork(
          indexBookProgram({
            bookId: book.id,
            numPages,
            startPage,
            skipPages,
            extract: (pageNumber) => {
              const m = usePdfStore.getState().getFooterMaskForPage(book.id, pageNumber)
              return extractPageParagraphs(loadedDoc, pageNumber, m)
            },
            saveChunks: (chunks) => window.electron.savePageDataMany(chunks),
            processJob: (pageNumber, items) =>
              window.electron.processJob(pageNumber, book.id, items),
            onAdvance: () => useIndexingStore.getState().advance(book.id),
            onFinish: () => useIndexingStore.getState().finish(book.id),
            onError: (msg) => useIndexingStore.getState().error(book.id, msg)
          })
        )
      } catch (err) {
        useIndexingStore.getState().error(book.id, err instanceof Error ? err.message : String(err))
      }
    }

    void run()

    return () => {
      state.cancelled = true
      if (fiber) Effect.runFork(Fiber.interrupt(fiber))
      if (docHolder.current) void docHolder.current.destroy()
    }
  }, [pdfBytes, book.id, book.location, book.lastParagraph])

  const handleCreatePdfHighlight = async (color: HighlightColor): Promise<void> => {
    if (!selectionPopover || !bookSyncId) return
    const { locator, text } = selectionPopover
    setSelectionPopover(null)
    try {
      const handle = await applyHighlightWithUndoPdf({
        target: {
          applyVisual: () => {
            setHighlights((prev) => [
              ...prev,
              {
                id: `pending-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
                bookId: bookSyncId,
                format: 'pdf',
                cfiRange: null,
                locator: JSON.stringify(locator),
                text,
                color,
                note: '',
                chapter: null,
                createdAt: new Date().toISOString(),
                updatedAt: null,
                syncId: null,
                syncVersion: 0,
                isDirty: 1,
                isDeleted: 0
              }
            ])
          },
          removeVisual: async () => {
            await refreshHighlights()
          }
        },
        bookSyncId,
        locator,
        text,
        color
      })
      setLastUndoable(handle)
      await refreshHighlights()
      toast.success('Highlight added', {
        action: { label: 'Undo', onClick: () => void handle.undo() }
      })
    } catch (err) {
      console.error('Failed to apply PDF highlight', err)
      // Pending sentinel may have been inserted by applyVisual before the
      // save failed; reconcile against DB to drop the ghost row.
      try {
        await refreshHighlights()
      } catch {
        // Best-effort cleanup; tolerate a follow-up reload restoring truth.
      }
      toast.error('Could not save highlight')
    }
  }

  const handleHighlightClick = (row: HighlightRow, e: ReactMouseEvent<HTMLDivElement>): void => {
    setInlinePopover({
      rowId: row.id,
      position: { x: e.clientX, y: e.clientY - 8 },
      currentColor: row.color as HighlightColor
    })
  }

  const handleInlineColorChange = async (color: HighlightColor): Promise<void> => {
    if (!inlinePopover) return
    await updateHighlightColor(inlinePopover.rowId, color)
    setHighlights((prev) => prev.map((r) => (r.id === inlinePopover.rowId ? { ...r, color } : r)))
    setInlinePopover(null)
  }

  const handleInlineDelete = async (): Promise<void> => {
    if (!inlinePopover || !bookSyncId) return
    const row = highlights.find((r) => r.id === inlinePopover.rowId)
    if (!row) return
    setInlinePopover(null)
    const handle = await deleteHighlightByIdWithUndo({
      target: {
        applyVisual: async () => {
          await refreshHighlights()
        },
        removeVisual: async () => {
          // Local removal handled below; the DB delete is performed by the helper.
        }
      },
      rowId: row.id,
      snapshot: {
        bookId: row.bookId,
        format: row.format,
        cfiRange: row.cfiRange,
        locator: row.locator,
        text: row.text,
        color: row.color,
        note: row.note,
        chapter: row.chapter
      }
    })
    setHighlights((prev) => prev.filter((r) => r.id !== row.id))
    setLastUndoable(handle)
    toast.success('Highlight removed', {
      action: { label: 'Undo', onClick: () => void handle.undo() }
    })
  }

  return (
    <div
      ref={readerRootRef}
      className={cn(
        'relative h-screen w-full',
        !isDualPage && isFullscreen ? '' : '',
        'bg-gray-300'
      )}
    >
      <div
        ref={scrollContainerRef}
        data-testid="pdf-scroll-container"
        className="h-full w-full overflow-y-scroll overflow-x-hidden"
        // overflowAnchor: the browser's built-in scroll-anchoring fights the
        // virtualizer's `adjustments` mechanism on backward scroll, producing
        // a back-and-forth jitter when an upper page (re)mounts. Disabling it
        // is the official tanstack/virtual recommendation for variable-size
        // virtualizers (see examples/dynamic).
        // contain: strict isolates layout/paint to this subtree, which is also
        // recommended for the dynamic-size pattern. NOTE: `contain: strict`
        // (which includes `paint`) makes this element a containing block for
        // `position: fixed` descendants — so fixed overlays (AIChatOrb,
        // ChatPanel, etc.) MUST be rendered as siblings, not
        // children, of this div. Otherwise they anchor to the scroll
        // container's top and scroll away with the content.
        style={{ overflowAnchor: 'none', contain: 'strict' }}
      >
        {/* Main PDF Viewer Area */}
        <div className="flex items-center justify-center  px-2 py-1">
          {loadError ? (
            <div className={cn('p-4 text-center', getTextColor())}>
              <p className="text-red-500">Failed to load PDF: {loadError}</p>
            </div>
          ) : null}
          {!pdfProxy && !loadError && (
            <div className="w-full h-screen grid place-items-center">
              <Loader />
            </div>
          )}
          {pdfProxy && documentContextValue ? (
            <DocumentContext.Provider value={documentContextValue}>
              <div className="flex items-center justify-center flex-col">
                <div
                  style={{
                    height: `${virtualizer.getTotalSize()}px`,
                    width: '100%',
                    position: 'relative'
                  }}
                >
                  {/*
                Recommended dynamic-virtualizer layout (per tanstack/virtual
                examples/dynamic): one absolute wrapper positioned at the
                first visible item's start, with items flowing naturally
                inside. The previous per-item `position:absolute` +
                `transform: translateY(item.start)` pattern made every
                item independently anchored, so when an upper item was
                re-measured during backward scroll, every item below it
                had to re-render with a new transform — racing the
                virtualizer's scrollTop adjustment and producing a visible
                jitter at page boundaries. With the natural-flow pattern
                only the wrapper's translateY needs updating; items below
                a re-measured one shift naturally with no transform churn.
              */}
                  <div
                    style={{
                      position: 'absolute',
                      top: 0,
                      left: 0,
                      width: '100%',
                      transform: `translateY(${virtualItems[0]?.start ?? 0}px)`
                    }}
                  >
                    {virtualItems.map((virtualItem) => (
                      <div
                        key={virtualItem.key}
                        data-index={virtualItem.index}
                        ref={setPageNodeRef}
                        className="flex w-full justify-center"
                        style={{
                          // Render the inter-page gap as natural margin so the
                          // virtualizer's `gap` config matches the actual DOM
                          // (virtualizer counts N-1 gaps for N items, so the
                          // last item gets no margin).
                          marginBottom: virtualItem.index < pageCount - 1 ? PAGE_GAP : 0
                        }}
                      >
                        <div
                          className="bg-white shadow-lg relative"
                          data-page-number={virtualItem.index + 1}
                          style={{ width: pageWidth }}
                        >
                          <PageComponent
                            key={`page-${virtualItem.index + 1}`}
                            pdf={pdfProxy}
                            thispageNumber={virtualItem.index + 1}
                            pdfWidth={pageWidth}
                            pdfHeight={pdfHeight}
                            isDualPage={isDualPage}
                            bookId={bookIdStr}
                            onRenderComplete={handlePageRendered}
                            onPageReady={(num, info) => {
                              pageInfoRef.current.set(num, info)
                            }}
                            highlights={highlights}
                            onHighlightClick={handleHighlightClick}
                            seekTo={pdfReader.seekTo}
                          />
                          <div className="group/page absolute bottom-1 left-0 right-0 text-center py-1">
                            <span className="text-xs text-gray-400">
                              <span>{virtualItem.index + 1}</span>
                              {pageCount > 0 && (
                                <span className="hidden group-hover/page:inline">
                                  {' '}
                                  of {pageCount}
                                </span>
                              )}
                            </span>
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </DocumentContext.Provider>
          ) : null}
        </div>
      </div>

      {/* All overlays below live OUTSIDE the scroll container so their
          `position: fixed` styles anchor to the viewport (the scroll
          container has `contain: strict` which would otherwise trap them). */}

      {AuthDialog}

      {/* AI chat orb */}
      {isChatting ? (
        <AIChatOrb chatStatus={chatStatus} onClick={() => setChatPanelOpen((prev) => !prev)} />
      ) : null}

      {/* Voice chat launcher — paired above the TTS play orb */}
      <VoiceChatLauncher />

      {/* TTS Controls — visually hidden while AI chat is active (stays mounted to avoid audio cleanup) */}
      <div style={{ display: isChatting ? 'none' : 'contents' }}>
        <TTSControls key={book.id.toString()} bookId={book.id.toString()} />
      </div>

      {/* Chat Panel */}
      <ChatPanel
        bookId={book.id}
        bookSyncId={bookSyncId}
        bookTitle={book.title}
        rendition={null}
        open={chatPanelOpen}
        onOpenChange={setChatPanelOpen}
      />
      {/* TOC Sidebar */}
      <ReaderTOC
        open={tocOpen}
        onOpenChange={setTocOpen}
        bookSyncId={bookSyncId}
        onBookmarkNavigate={(location) => {
          const pageNum = parseInt(location, 10)
          if (pageNum > 0) {
            pdfReader.seekTo(pageNum)
            setTocOpen(false)
          }
        }}
        tocContent={
          <div
            className={cn(
              '[&_a]:block [&_a]:py-3 [&_a]:px-4 [&_a]:cursor-pointer',
              '[&_a]:transition-all [&_a]:duration-200',
              '[&_a]:border-b [&_a]:font-medium',
              '[&_a]:text-gray-700 [&_a:hover]:bg-gray-100 [&_a:hover]:text-black [&_a]:border-gray-100 [&_a:hover]:pl-6'
            )}
          >
            {pdfProxy ? <Outline pdf={pdfProxy} onItemClick={onItemClick} /> : null}
          </div>
        }
      />
      {/* Thumbnail Sidebar */}
      <Sheet open={thumbOpen} onOpenChange={setThumbOpen}>
        <SheetContent
          side="left"
          className={cn(
            'w-[200px] sm:w-[240px] p-0',
            theme === ThemeType.Dark ? 'bg-gray-900 border-gray-700' : 'bg-white border-gray-200'
          )}
        >
          <SheetHeader
            className={cn(
              'p-4 border-b sticky top-0 z-10',
              theme === ThemeType.Dark ? 'border-gray-700 bg-gray-900' : 'border-gray-200 bg-white'
            )}
          >
            <SheetTitle className={getTextColor()}>Pages</SheetTitle>
          </SheetHeader>
          <div className="h-[calc(100vh-73px)]">
            <ThumbnailSidebar
              onClose={() => setThumbOpen(false)}
              onNavigate={onThumbnailNavigate}
            />
          </div>
        </SheetContent>
      </Sheet>
      {selectionPopover ? (
        <SelectionPopover
          cfiRange={''}
          selectedText={selectionPopover.text}
          position={selectionPopover.anchorPos}
          onHighlight={(color) => void handleCreatePdfHighlight(color)}
          onClose={() => setSelectionPopover(null)}
        />
      ) : null}
      {inlinePopover ? (
        <HighlightActionPopover
          position={inlinePopover.position}
          currentColor={inlinePopover.currentColor}
          onSelectColor={(c) => void handleInlineColorChange(c)}
          onEditNote={() => {
            const row = highlights.find((r) => r.id === inlinePopover.rowId)
            if (row) setEditingNoteRow(row)
            setInlinePopover(null)
          }}
          onDelete={() => void handleInlineDelete()}
          onClose={() => setInlinePopover(null)}
        />
      ) : null}
      <NoteEditor
        highlight={editingNoteRow}
        open={editingNoteRow !== null}
        onOpenChange={(open) => {
          if (!open) setEditingNoteRow(null)
        }}
        onSaved={async () => {
          await refreshHighlights()
        }}
      />
      {/* Navigation history back-pill overlay */}
      <NavigationHistoryFooter />
    </div>
  )
}

export default PdfView
