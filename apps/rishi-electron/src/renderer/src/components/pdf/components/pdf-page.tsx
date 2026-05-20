import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
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
type Transform = [number, number, number, number, number, number]

const PARAGRAPH_INDEX_PER_PAGE = 10000

/**
 * Pure factory for the PDF text-layer renderer. Extracted from the component
 * closure so the declarative TTS-highlight behavior can be unit-tested
 * without standing up a full `<PdfPage>` (which needs a real pdf.js page).
 *
 * Contract:
 *  - If `highlightedParagraph` is null, returns plain text for every item.
 *  - If `highlightedParagraph` is set and the text item's y-coordinate (the
 *    6th entry of the transform matrix) falls within
 *    `[dimensions.bottom, dimensions.top]`, wraps the text in `<mark>`.
 *  - Items without a transform always pass through as plain text.
 */
export function makeCustomTextRenderer(
  highlightedParagraph: { dimensions: { top: number; bottom: number } } | null
) {
  return ({ str, transform }: { str: string; transform: number[] | undefined }): string => {
    if (!highlightedParagraph || !transform) return str
    const t = transform as Transform
    const isBelowOrEqualTop = t[5] <= highlightedParagraph.dimensions.top
    const isAboveOrEqualBottom = t[5] >= highlightedParagraph.dimensions.bottom
    if (isBelowOrEqualTop && isAboveOrEqualBottom) {
      return `<mark style="background-color: rgb(255,255,204);">${str}</mark>`
    }
    return str
  }
}

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
  onHighlightClick
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

  const wrapperRef = useRef<HTMLDivElement | null>(null)
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
    const canvas = wrapperRef.current?.querySelector('canvas') ?? null
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
  }, [pageNumber, bookId, setIsPdfRendered, onRenderComplete])

  const handleGetTextSuccess = useCallback(
    (data: Parameters<NonNullable<Parameters<typeof Page>[0]['onGetTextSuccess']>>[0]) => {
      setPageData(pageNumber, data)
    },
    [pageNumber, setPageData]
  )

  const handleLoadSuccess = useCallback(
    (page: PDFPageProxy) => {
      setPdfPage(page)
      const pageEl =
        wrapperRef.current?.querySelector<HTMLElement>('.react-pdf__Page') ?? null
      if (pageEl && onPageReady) onPageReady(pageNumber, { pageEl, page })
    },
    [pageNumber, onPageReady]
  )

  return (
    <div ref={wrapperRef} style={{ position: 'relative' }}>
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
      {pdfPage && wrapperRef.current && highlights && onHighlightClick && (
        <HighlightLayer
          pageNumber={pageNumber}
          pageEl={
            wrapperRef.current.querySelector<HTMLElement>('.react-pdf__Page') ?? wrapperRef.current
          }
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
      )}
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
