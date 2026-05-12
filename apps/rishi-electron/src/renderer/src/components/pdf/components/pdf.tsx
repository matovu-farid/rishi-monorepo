import React, { useEffect, useState, useMemo, useRef } from 'react'
import { IconButton } from '@/components/ui/IconButton'
import { ThemeType } from '@/themes/common'
import { Loader2, Menu as MenuIcon, LayoutGrid } from 'lucide-react'
import AIChatOrb from '../../chat/AIChatOrb'
import VoiceChatLauncher from '../../chat/VoiceChatLauncher'
import { ChatPanel } from '@/components/chat/ChatPanel'
import { Document, Outline, pdfjs } from 'react-pdf'
import type { DocumentInitParameters } from 'pdfjs-dist/types/src/display/api'
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
import { useSetupMenu } from '../hooks/useSetupMenu'
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
import { BackButton } from '@/components/BackButton'
import { BookmarkButton } from '@/components/bookmarks/BookmarkButton'
import { ReaderToolbar } from '@/components/reader/ReaderToolbar'
import { ReaderTOC } from '@/components/reader/ReaderTOC'
import { useChatStore } from '@/stores/chatStore'
import { useRequireAuth } from '@/hooks/useRequireAuth'

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

  const currentPageNumber = usePdfStore((s) => s.pageNumber)

  const { AuthDialog } = useRequireAuth()
  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)

  const scrollContainerRef = useRef<HTMLDivElement>(null)
  useScrolling(scrollContainerRef)

  useUpdateCoverIMage(book)
  useSetupMenu()
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

  // Configure PDF.js options with CDN fallback for better font and image support
  const pdfOptions = useMemo<DocumentInitParameters>(
    () => ({
      cMapPacked: true,

      verbosity: 0
    }),
    []
  )
  const { isDualPage, pdfWidth, pdfHeight, dualPageWidth, isFullscreen } = usePdfNavigation()

  // Setup View submenu in the app menu for PDF view
  const isDualPageRef = useRef(isDualPage)

  // Keep ref in sync with current value
  useEffect(() => {
    isDualPageRef.current = isDualPage
  }, [isDualPage])

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

  const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage)
  const { virtualizer, virtualItems, pageRefs, handlePageRendered } = useVirualization(
    scrollContainerRef,
    book
  )

  // pdfReader owns navigation + persistence via xstate. Replaces the old
  // useCurrentPageNumber tangle of useEffects (initial-seek lockout, debounced
  // save with unmount-flush, paragraph publishing) with one explicit machine
  // whose state can't be stomped from outside.
  const pdfReader = usePdfReader(book, virtualizer, scrollContainerRef)

  function onDocumentLoadSuccess(pdf: PDFDocumentProxy): void {
    setPageCount(pdf.numPages)
    setPdfDocProxy(pdf)
    pdfReader.sendDocLoaded(pdf.numPages)
  }

  function onItemClick({ pageNumber: itemPageNumber }: { pageNumber: number }) {
    pdfReader.seekTo(itemPageNumber)
    setTocOpen(false)
  }

  function onThumbnailNavigate(pageNumber: number) {
    pdfReader.seekTo(pageNumber)
  }

  // PDF data loading via Electron IPC
  const [pdfData, setPdfData] = useState<{ data: Uint8Array } | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setLoadError(null)
    setPdfData(null)

    window.electron
      .readFile(book.filepath)
      .then((data) => {
        if (cancelled) return
        let arr: Uint8Array
        if (data instanceof ArrayBuffer) {
          arr = new Uint8Array(data)
        } else if (ArrayBuffer.isView(data)) {
          arr = new Uint8Array(
            (data as any).buffer,
            (data as any).byteOffset,
            (data as any).byteLength
          )
        } else {
          const values = Object.values(data as any) as number[]
          arr = new Uint8Array(values)
        }
        setPdfData({ data: arr })
      })
      .catch((err) => {
        if (!cancelled) {
          console.error('[pdf] readFile failed:', err)
          setLoadError(err instanceof Error ? err.message : String(err))
        }
      })

    return () => {
      cancelled = true
    }
  }, [book.filepath])

  // pdfjs transfers (detaches) the underlying ArrayBuffer when a Document
  // loads. Give each <Document> consumer its own clone so the main viewer
  // and the TOC sidebar don't fight over a single buffer — otherwise
  // whichever loads second sees an empty buffer and renders
  // "Failed to load PDF file."
  const mainPdfFile = useMemo(
    () => (pdfData ? { data: new Uint8Array(pdfData.data) } : null),
    [pdfData]
  )
  const tocPdfFile = useMemo(
    () => (pdfData ? { data: new Uint8Array(pdfData.data) } : null),
    [pdfData]
  )

  // Background indexing: extract per-page text and ship to the embedding/vector
  // pipeline so chat/RAG works for this book. Runs as an Effect fiber with
  // bounded concurrency; interrupted when the book unmounts.
  useEffect(() => {
    if (!pdfData?.data) return

    let cancelled = false
    let fiber: Fiber.RuntimeFiber<void, Error> | null = null
    let doc: Awaited<ReturnType<typeof loadPdfDocument>> | null = null

    const run = async (): Promise<void> => {
      try {
        doc = await loadPdfDocument(pdfData.data)
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
  }, [pdfData?.data, book.id])

  return (
    <div className={cn('relative h-screen w-full', !isDualPage && isFullscreen ? '' : '', 'bg-gray-300')}>
      <div
        ref={scrollContainerRef}
        className="h-full w-full overflow-y-scroll"
        // overflowAnchor: the browser's built-in scroll-anchoring fights the
        // virtualizer's `adjustments` mechanism on backward scroll, producing
        // a back-and-forth jitter when an upper page (re)mounts. Disabling it
        // is the official tanstack/virtual recommendation for variable-size
        // virtualizers (see examples/dynamic).
        // contain: strict isolates layout/paint to this subtree, which is also
        // recommended for the dynamic-size pattern. NOTE: `contain: strict`
        // (which includes `paint`) makes this element a containing block for
        // `position: fixed` descendants — so fixed overlays (ReaderToolbar,
        // AIChatOrb, ChatPanel, etc.) MUST be rendered as siblings, not
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
        {!pdfData && !loadError && (
          <div className={cn('w-full h-screen grid place-items-center', getTextColor())}>
            <Loader2 size={20} className="animate-spin" />
          </div>
        )}
        {mainPdfFile && (
          <Document
            className="flex items-center justify-center flex-col"
            file={mainPdfFile}
            options={pdfOptions}
            onLoadSuccess={onDocumentLoadSuccess}
            onItemClick={onItemClick}
            error={
              <div className={cn('p-4 text-center', getTextColor())}>
                <p className="text-red-500">Error loading PDF. Please try again.</p>
              </div>
            }
            loading={
              <div className={cn('w-full h-screen grid place-items-center', getTextColor())}>
                <Loader2 size={20} className="animate-spin" />
              </div>
            }
            externalLinkTarget="_blank"
            externalLinkRel="noopener noreferrer nofollow"
          >
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
          </Document>
        )}
        </div>
      </div>

      {/* All overlays below live OUTSIDE the scroll container so their
          `position: fixed` styles anchor to the viewport (the scroll
          container has `contain: strict` which would otherwise trap them). */}

      {/** White loading screen */}
      {!hasNavigatedToPage && (
        <div className="fixed inset-0 grid place-items-center bg-white z-100 pointer-events-none">
          <Loader2 size={20} className="animate-spin" />
        </div>
      )}

      {/* Fixed Top Bar — auto-hides after 2s */}
      <ReaderToolbar
        panelsOpen={tocOpen || thumbOpen}
        leftContent={
          <IconButton
            color="inherit"
            onClick={() => setTocOpen(true)}
            className={cn('hover:bg-black/10 dark:hover:bg-white/10 border-none', getTextColor())}
            aria-label="Open table of contents"
          >
            <MenuIcon size={20} />
          </IconButton>
        }
      >
        <BackButton />

        <IconButton
          color="inherit"
          onClick={() => setThumbOpen(true)}
          className={cn('hover:bg-black/10 dark:hover:bg-white/10 border-none', getTextColor())}
          aria-label="Open page thumbnails"
        >
          <LayoutGrid size={20} />
        </IconButton>

        <BookmarkButton
          bookSyncId={bookSyncId}
          location={String(currentPageNumber)}
          label={`Page ${currentPageNumber}`}
          className={cn('hover:bg-black/10 dark:hover:bg-white/10 border-none', getTextColor())}
        />
      </ReaderToolbar>

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
            {tocPdfFile && (
              <Document file={tocPdfFile} options={pdfOptions}>
                <Outline onItemClick={onItemClick} />
              </Document>
            )}
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
