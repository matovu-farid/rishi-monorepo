import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useState,
  type MouseEvent as ReactMouseEvent
} from 'react'
import { Page } from 'react-pdf'
import type { PDFDocumentProxy, PDFPageProxy } from 'pdfjs-dist'

import { usePdfStore } from '@/stores/pdfStore'
import { registerPdfCanvas, unregisterPdfCanvas } from '@/modules/pageCapture/pdfCanvasRegistry'
import Loader from '@/components/Loader'
import { HighlightLayer } from '../HighlightLayer'
import type { HighlightRow } from '@/modules/highlight-storage'
import type { ViewportLike } from '@/modules/pdf-locator'
import { navigationHistoryActor } from '@/machines/navigationHistory/navigationHistoryActor'
import { makeCustomTextRenderer } from './makeCustomTextRenderer'

const PARAGRAPH_INDEX_PER_PAGE = 10000

function PageComponentInner({
  thispageNumber: pageNumber,
  pdfHeight,
  pdfWidth,
  isDualPage = false,
  bookId,
  onRenderComplete,
  pdf,
  onPageReady,
  highlights,
  onHighlightClick,
  seekTo
}: {
  thispageNumber: number
  pdfHeight?: number
  pdfWidth?: number
  isDualPage?: boolean
  bookId: string
  onRenderComplete?: () => void
  // pdf prop is required when <Page> is rendered outside a <Document> wrapper.
  // PdfView owns the proxy via the warm-restore cache, so we pass it down
  // explicitly here.
  pdf: PDFDocumentProxy
  onPageReady?: (pageNumber: number, info: { pageEl: HTMLElement; page: PDFPageProxy }) => void
  highlights?: HighlightRow[]
  onHighlightClick?: (row: HighlightRow, e: ReactMouseEvent<HTMLDivElement>) => void
  seekTo?: (page: number) => void
}) {
  // Subscriptions: keep them to scalar values only so unrelated store writes
  // (currentViewParagraphs reference churn during TTS, pageNumber bumps from
  // scrolling) don't re-render every mounted page. Larger reads happen
  // conditionally via the selector below or via getState() inside callbacks.
  const isHighlighting = usePdfStore((s) => s.isHighlighting)
  const highlightedIdx = usePdfStore((s) => s.highlightedParagraphIndex)

  // Only ONE page has the active highlight at any moment. Other pages should
  // be inert. Cheap math, no extra subscription.
  const isMyHighlightedPage =
    isHighlighting && Math.floor(Number(highlightedIdx) / PARAGRAPH_INDEX_PER_PAGE) === pageNumber

  // Subscribe to the *resolved paragraph object* (or null) instead of the
  // whole paragraphs array. When `isMyHighlightedPage` is false the selector
  // returns null on every store update — `null === null` → no re-render.
  // When this page is highlighted, only this single page reacts to paragraph
  // updates.
  const highlightedParagraph = usePdfStore((s) =>
    isMyHighlightedPage
      ? (s.currentViewParagraphs.find((p) => p.index === s.highlightedParagraphIndex) ?? null)
      : null
  )

  const setIsPdfRendered = usePdfStore((s) => s.setIsPdfRendered)
  const setPageData = usePdfStore((s) => s.setPageData)

  // Callback-ref-as-state: tracking the wrapper as state (set via the JSX
  // ref={setWrapper} callback) lets us read it during render to derive
  // HighlightLayer's `pageEl` prop. A `useRef` would force us to read
  // `wrapperRef.current` during render, which the new
  // `react-hooks/refs` rule flags because React Compiler can't prove the
  // ref's commit-time value is the one we'll see at the next render.
  const [wrapper, setWrapper] = useState<HTMLDivElement | null>(null)
  const [pdfPage, setPdfPage] = useState<PDFPageProxy | null>(null)

  // Stable text renderer keyed on highlight inputs. react-pdf re-runs the
  // text layer when this prop's identity changes — without useCallback we'd
  // force a full text re-layout on every parent render. The actual decision
  // logic lives in the exported `makeCustomTextRenderer` so it can be unit
  // tested without rendering the full <PdfPage>.
  const customTextRenderer = useMemo(
    () => makeCustomTextRenderer(highlightedParagraph),
    [highlightedParagraph]
  )

  useEffect(() => () => unregisterPdfCanvas(pageNumber), [pageNumber])

  const handleRenderSuccess = useCallback(() => {
    const canvas = wrapper?.querySelector('canvas') ?? null
    if (canvas instanceof HTMLCanvasElement) {
      registerPdfCanvas(pageNumber, canvas)
    }
    // Read pageNumber via getState() so we don't subscribe — `pageNumber`
    // changes on every scroll-driven page advance and would otherwise re-
    // render every mounted page.
    const currentPage = usePdfStore.getState().pageNumber
    if (currentPage === pageNumber) {
      setIsPdfRendered(bookId, true)
    }
    onRenderComplete?.()
  }, [pageNumber, bookId, setIsPdfRendered, onRenderComplete, wrapper])

  const handleGetTextSuccess = useCallback(
    (data: Parameters<NonNullable<Parameters<typeof Page>[0]['onGetTextSuccess']>>[0]) => {
      setPageData(pageNumber, data)
    },
    [pageNumber, setPageData]
  )

  const handleLoadSuccess = useCallback(
    (page: PDFPageProxy) => {
      setPdfPage(page)
      const pageEl = wrapper?.querySelector<HTMLElement>('.react-pdf__Page') ?? null
      if (pageEl && onPageReady) onPageReady(pageNumber, { pageEl, page })
    },
    [pageNumber, onPageReady, wrapper]
  )

  // Intercept react-pdf annotation-layer link clicks before the default handler
  // fires. The annotation layer renders <a> elements; for internal "go-to-page"
  // actions, react-pdf / pdf.js sets href to "#page=N". We capture the click,
  // extract the target page, dispatch JUMP_REQUESTED to the navigation history
  // machine, and then call seekTo so the reader scrolls to the target.
  const handleAnnotationClick = useCallback(
    (e: ReactMouseEvent<HTMLDivElement>): void => {
      if (!seekTo) return
      const link = (e.target as HTMLElement).closest('a')
      if (!link) return
      const href = link.getAttribute('href')
      const targetPageStr =
        link.getAttribute('data-page-number') ?? href?.match(/page=(\d+)/)?.[1] ?? null
      if (!targetPageStr) return
      const targetPage = Number(targetPageStr)
      if (!Number.isFinite(targetPage) || targetPage <= 0) return
      e.preventDefault()
      const currentPage = usePdfStore.getState().pageNumber
      navigationHistoryActor.send({
        type: 'JUMP_REQUESTED',
        from: { kind: 'pdf', page: currentPage, offset: 0 },
        fromTts: null,
        to: { kind: 'pdf', page: targetPage, offset: 0 },
        source: 'link',
        fromLabel: `p. ${currentPage}`
      })
      seekTo(targetPage)
    },
    [seekTo]
  )

  return (
    <div ref={setWrapper} style={{ position: 'relative' }}>
      {/* onClickCapture intercepts annotation-layer link clicks before react-pdf's handler */}
      <div onClickCapture={handleAnnotationClick}>
        <Page
          pdf={pdf}
          pageNumber={pageNumber}
          key={pageNumber.toString()}
          customTextRenderer={customTextRenderer}
          height={isDualPage ? pdfHeight : undefined}
          width={isDualPage ? undefined : pdfWidth}
          className="rounded shadow-lg"
          renderTextLayer={true}
          renderAnnotationLayer={true}
          canvasBackground="white"
          onGetTextSuccess={handleGetTextSuccess}
          loading={
            <div
              className="bg-white grid place-items-center"
              style={{ width: pdfWidth, aspectRatio: '8.5 / 11' }}
            >
              <Loader />
            </div>
          }
          onRenderSuccess={handleRenderSuccess}
          onLoadSuccess={handleLoadSuccess}
        />
      </div>
      {pdfPage && wrapper && highlights && onHighlightClick ? (
        <HighlightLayer
          pageNumber={pageNumber}
          pageEl={wrapper.querySelector<HTMLElement>('.react-pdf__Page') ?? wrapper}
          viewport={
            pdfPage.getViewport({
              // pdfjs page.view = [x0, y0, x1, y1]; native width = view[2], native height = view[3].
              // In dual-page mode the parent passes `height` to <Page> (and width=undefined), so the
              // rendered scale is height-driven. Match accordingly so HighlightLayer's screen rects
              // line up with the rendered page in both layouts.
              scale:
                isDualPage && pdfHeight
                  ? pdfHeight / pdfPage.view[3]
                  : (pdfWidth ?? pdfPage.view[2]) / pdfPage.view[2]
            }) as unknown as ViewportLike
          }
          highlights={highlights}
          onHighlightClick={onHighlightClick}
        />
      ) : null}
    </div>
  )
}

// Memoize on prop identity. The parent PdfView passes a fresh
// `onRenderComplete` closure each render but the virtualizer reconciles items
// by `key` + index — when neither the page index nor sizing props change the
// memo bails out, and our internal handleRenderSuccess captures pageNumber
// stably so a re-issued onRenderComplete prop still produces a fresh callback
// only when needed. The win is during scroll, when nothing about a given
// page's props actually changes but the parent re-renders.
export const PageComponent = memo(PageComponentInner)
