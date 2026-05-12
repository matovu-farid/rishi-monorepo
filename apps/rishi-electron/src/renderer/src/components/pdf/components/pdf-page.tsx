import { memo, useCallback } from 'react'
import { Page } from 'react-pdf'
import type { PDFDocumentProxy } from 'pdfjs-dist'

import { usePdfStore } from '@/stores/pdfStore'
import { Loader2 } from 'lucide-react'
type Transform = [number, number, number, number, number, number]

const PARAGRAPH_INDEX_PER_PAGE = 10000

function PageComponentInner({
  thispageNumber: pageNumber,
  pdfHeight,
  pdfWidth,
  isDualPage = false,
  bookId,
  onRenderComplete,
  pdf
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
    isHighlighting &&
    Math.floor(Number(highlightedIdx) / PARAGRAPH_INDEX_PER_PAGE) === pageNumber

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

  // Stable text renderer keyed on highlight inputs. react-pdf re-runs the
  // text layer when this prop's identity changes — without useCallback we'd
  // force a full text re-layout on every parent render.
  const customTextRenderer = useCallback(
    ({ str, transform }: { str: string; transform: number[] | undefined }) => {
      if (!highlightedParagraph || !transform) return str
      const t = transform as Transform
      const isBelowOrEqualTop = t[5] <= highlightedParagraph.dimensions.top
      const isAboveOrEqualBottom = t[5] >= highlightedParagraph.dimensions.bottom
      if (isBelowOrEqualTop && isAboveOrEqualBottom) {
        return `<mark style="background-color: rgb(255,255,204);">${str}</mark>`
      }
      return str
    },
    [highlightedParagraph]
  )

  const handleRenderSuccess = useCallback(() => {
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

  return (
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
          <Loader2 size={20} className="animate-spin" />
        </div>
      }
      onRenderSuccess={handleRenderSuccess}
    />
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
