import React, { useEffect, useState, useMemo, useRef } from 'react'
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

import { cn } from '@/lib/utils'

// Import required CSS for text and annotation layers
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

import { usePdfStore } from '@/stores/pdfStore'
import { ThumbnailSidebar } from './thumbnail-sidebar'
import TTSControls from '@/components/tts/TTSControls'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { useUpdateCoverIMage } from '../hooks/useUpdateCoverIMage'
import { useScrolling } from '../hooks/useScrolling'
import { usePdfNavigation } from '../hooks/usePdfNavigation'
import { PageComponent } from './pdf-page'
import { PDFDocumentProxy } from 'pdfjs-dist'
import { useVirualization } from '../hooks/useVirualization'
import { PAGE_GAP } from '../utils/constants'
import { parsePdfLocation } from '@/lib/pdfLocation'
import { Effect, Fiber } from 'effect'
import { indexBookProgram } from '@/services/indexing/index-program'
import { loadPdfDocument, extractPageParagraphs } from '@/services/indexing/text-extraction'
import { useIndexingStore } from '@/stores/indexingStore'
import { usePdfReader } from '@/hooks/usePdfReader'
import type { Book } from '@/lib/api'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useChatStore } from '@/stores/chatStore'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { useMenuCommands } from '@/hooks/useMenuCommands'
import { toggleBookmark, publishBookmarksToMenu } from '@/modules/bookmark-storage'
import { useQueryClient } from '@tanstack/react-query'

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
  useScrolling(scrollContainerRef)

  useUpdateCoverIMage(book)
  // Ref for the scrollable container

  const resetParaphState = usePdfStore((s) => s.resetParagraphState)

  useEffect(() => {
    return () => {
      resetParaphState()
      setThumbOpen(false)
      setPdfDocProxy(null)
    }
  }, [])

  // Scoped playerStore subscriptions for PDF page navigation and highlighting.
  // These must be inside the component lifecycle so they are cleaned up when
  // navigating away from the PDF reader — otherwise they leak across formats.
  //
  // Empty deps `[]` is intentional: PdfView is mounted with `key={book.id}` in
  // books.$id.lazy.tsx, so a book switch triggers a full remount. The closures
  // over `nextPage`/`previousPage` are stable module-level functions, and
  // `usePdfStore`/`usePlayerStore` reads use `.getState()` or subscriptions
  // which always see the latest values.
  useEffect(() => {
    const unsubPage = usePlayerStore.subscribe(
      (s) => s.pageRequest,
      (request) => {
        if (request === 'next') nextPage()
        if (request === 'prev') previousPage()
        if (request) usePlayerStore.getState().clearPageRequest()
      }
    )

    const unsubActive = usePlayerStore.subscribe(
      (s) => s.activeParagraph,
      (paragraph) => {
        if (paragraph) {
          usePdfStore.getState().setIsHighlighting(true)
          usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index)
        }
      }
    )

    const unsubState = usePlayerStore.subscribe(
      (s) => s.playingState,
      (state) => {
        usePdfStore.getState().setIsHighlighting(state === 'playing')
      }
    )

    return () => {
      unsubPage()
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
  // handler. Cancellation guards against unmount during the async read.
  useEffect(() => {
    if (!bookSyncId) return
    let cancelled = false
    void (async () => {
      if (cancelled) return
      await publishBookmarksToMenu(bookSyncId)
    })()
    return () => {
      cancelled = true
    }
  }, [bookSyncId])

  // Publish the book title to main so the Window menu's open-books submenu
  // shows the real title (not whatever the DB had at window-creation time).
  useEffect(() => {
    const e = (window as unknown as { electron: { send(c: string, p: unknown): void } }).electron
    e?.send('window:setBookTitle', { bookId: book.id, title: book.title })
  }, [book.id, book.title])

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
    if (!e) return
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

  // pdfReader owns navigation + persistence via xstate. Replaces the old
  // useCurrentPageNumber tangle of useEffects (initial-seek lockout, debounced
  // save with unmount-flush, paragraph publishing) with one explicit machine
  // whose state can't be stomped from outside.
  const pdfReader = usePdfReader(book, virtualizer, scrollContainerRef)

  // Wire native-menu commands. Toolbar buttons remain the primary entry
  // point; menu items dispatch the same actions. Setters from useState and
  // store actions read via getState() are stable identities, so this memo
  // only rebinds when `requireAuth`/`bookSyncId`/`book.id` change.
  const menuHandlers = useMemo(
    () => ({
      toggleTOC: () => setTocOpen((v) => !v),
      toggleThumbnails: () => setThumbOpen((v) => !v),
      toggleDualPage: () =>
        usePdfStore.setState((s) => ({ isDualPage: !s.isDualPage })),
      addBookmark: () => {
        if (!bookSyncId) return
        const pageNum = usePdfStore.getState().pageNumber
        void toggleBookmark({
          bookSyncId,
          location: String(pageNum),
          label: `Page ${pageNum}`
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
    [requireAuth, bookSyncId, queryClient, setThumbOpen]
  )
  useMenuCommands(menuHandlers)

  function onItemClick({ pageNumber: itemPageNumber }: { pageNumber: number }) {
    pdfReader.seekTo(itemPageNumber)
    setTocOpen(false)
  }

  function onThumbnailNavigate(pageNumber: number) {
    pdfReader.seekTo(pageNumber)
  }

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
    let cancelled = false
    setLoadError(null)

    if (getCachedPdf(book.id)) {
      // Cache hit — state already initialized from cache by useState.
      return () => {
        cancelled = true
      }
    }

    ;(async () => {
      try {
        const data = await window.electron.readFile(book.filepath)
        if (cancelled) return
        let bytes: Uint8Array
        if (data instanceof ArrayBuffer) {
          bytes = new Uint8Array(data)
        } else if (ArrayBuffer.isView(data)) {
          bytes = new Uint8Array(
            (data as any).buffer,
            (data as any).byteOffset,
            (data as any).byteLength
          )
        } else {
          bytes = new Uint8Array(Object.values(data as any) as number[])
        }
        // pdfjs detaches the buffer it parses; pass a clone so `bytes` stays
        // intact for indexing and re-parse.
        const loadingTask = pdfjs.getDocument({ data: bytes.slice(), ...pdfOptions })
        const proxy = await loadingTask.promise
        if (cancelled) {
          void proxy.destroy()
          return
        }
        setCachedPdf(book.id, proxy, bytes)
        setPdfProxy(proxy)
        setPdfBytes(bytes)
      } catch (err) {
        if (!cancelled) {
          console.error('[pdf] load failed:', err)
          setLoadError(err instanceof Error ? err.message : String(err))
        }
      }
    })()

    return () => {
      cancelled = true
    }
  }, [book.id, book.filepath])

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
  const linkServiceRef = useRef<LinkService>(null as unknown as LinkService)
  if (linkServiceRef.current === null) {
    linkServiceRef.current = new LinkService()
  }
  useEffect(() => {
    if (pdfProxy) linkServiceRef.current.setDocument(pdfProxy)
  }, [pdfProxy])

  const documentContextValue = useMemo(
    () =>
      pdfProxy
        ? {
            pdf: pdfProxy,
            linkService: linkServiceRef.current,
            onItemClick,
            registerPage: () => {},
            unregisterPage: () => {}
          }
        : null,
    // onItemClick reads pdfReader/setTocOpen via closure; both are stable
    // identities within a given mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [pdfProxy]
  )

  // Background indexing: extract per-page text and ship to the embedding/vector
  // pipeline so chat/RAG works for this book. Runs as an Effect fiber with
  // bounded concurrency; interrupted when the book unmounts.
  useEffect(() => {
    if (!pdfBytes) return

    let cancelled = false
    let fiber: Fiber.RuntimeFiber<void, Error> | null = null
    let doc: Awaited<ReturnType<typeof loadPdfDocument>> | null = null

    const run = async (): Promise<void> => {
      try {
        // Indexing keeps its own throwaway proxy — it walks every page and
        // can run after the visible reader unmounts. Sharing the cached
        // proxy would risk indexing destroying it on its own cleanup.
        doc = await loadPdfDocument(pdfBytes)
        if (cancelled) {
          await doc.destroy()
          doc = null
          return
        }

        const numPages = doc.numPages

        // Pages already in chunk_data don't need to be re-extracted or
        // re-embedded. Fetch them once upfront and skip them in the schedule.
        const indexedPages = await window.electron.getIndexedPageNumbers(book.id)
        if (cancelled) return
        const skipPages = new Set(indexedPages)

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
        const startPage = parsePdfLocation(book.location).page || 1

        const docRef = doc
        fiber = Effect.runFork(
          indexBookProgram({
            bookId: book.id,
            numPages,
            startPage,
            skipPages,
            extract: (pageNumber) => extractPageParagraphs(docRef, pageNumber),
            saveChunks: (chunks) => window.electron.savePageDataMany(chunks),
            processJob: (pageNumber, items) =>
              window.electron.processJob(pageNumber, book.id, items),
            onAdvance: () => useIndexingStore.getState().advance(book.id),
            onFinish: () => useIndexingStore.getState().finish(book.id),
            onError: (msg) => useIndexingStore.getState().error(book.id, msg)
          })
        )
      } catch (err) {
        useIndexingStore
          .getState()
          .error(book.id, err instanceof Error ? err.message : String(err))
      }
    }

    void run()

    return () => {
      cancelled = true
      if (fiber) Effect.runFork(Fiber.interrupt(fiber))
      if (doc) void doc.destroy()
    }
  }, [pdfBytes, book.id])

  return (
    <div className={cn('relative h-screen w-full', !isDualPage && isFullscreen ? '' : '', 'bg-gray-300')}>
      <div
        ref={scrollContainerRef}
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
        {loadError && (
          <div className={cn('p-4 text-center', getTextColor())}>
            <p className="text-red-500">Failed to load PDF: {loadError}</p>
          </div>
        )}
        {!pdfProxy && !loadError && (
          <div className="w-full h-screen grid place-items-center">
            <Loader />
          </div>
        )}
        {pdfProxy && documentContextValue && (
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
                    ref={(node) => {
                      if (node) {
                        pageRefs.current.set(virtualItem.index, node)
                      } else {
                        pageRefs.current.delete(virtualItem.index)
                      }
                      virtualizer.measureElement(node)
                    }}
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
                      style={{ width: pageWidth ?? 'auto' }}
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
                      />
                      <div className="group/page absolute bottom-1 left-0 right-0 text-center py-1">
                        <span className="text-xs text-gray-400">
                          <span>{virtualItem.index + 1}</span>
                          {pageCount > 0 && (
                            <span className="hidden group-hover/page:inline"> of {pageCount}</span>
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
        )}
        </div>
      </div>

      {/* All overlays below live OUTSIDE the scroll container so their
          `position: fixed` styles anchor to the viewport (the scroll
          container has `contain: strict` which would otherwise trap them). */}

      {AuthDialog}

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
            {pdfProxy && <Outline pdf={pdfProxy} onItemClick={onItemClick} />}
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
    </div>
  )
}

export default PdfView
