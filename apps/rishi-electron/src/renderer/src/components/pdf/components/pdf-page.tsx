import { Page } from "react-pdf";

import { usePdfStore } from "@/stores/pdfStore";
import { Loader2 } from "lucide-react";

type Transform = [number, number, number, number, number, number];

const PARAGRAPH_INDEX_PER_PAGE = 10000;
export function PageComponent({
  thispageNumber: pageNumber,
  pdfHeight,
  pdfWidth,
  isDualPage = false,
  bookId,
  onRenderComplete,
}: {
  thispageNumber: number;
  pdfHeight?: number;
  pdfWidth?: number;
  isDualPage?: boolean;
  bookId: string;
  onRenderComplete?: () => void;
}) {
  const isHighlighting = usePdfStore((s) => s.isHighlighting);
  const highlightedParagraphIndex = usePdfStore((s) => s.highlightedParagraphIndex);
  const currentViewParagraphs = usePdfStore((s) => s.currentViewParagraphs);
  const highlightedParagraph = currentViewParagraphs.find((p) => p.index === highlightedParagraphIndex);

  function isInsideParagraph(wordTransform: Transform) {
    // Return false if no paragraph is highlighted
    if (!highlightedParagraph) return false;

    const highlightedPageNumber = Math.floor(
      Number(highlightedParagraph.index) / PARAGRAPH_INDEX_PER_PAGE
    );
    if (highlightedPageNumber !== pageNumber) return false;
    const isBelowOrEqualTop =
      wordTransform[5] <= highlightedParagraph.dimensions.top;
    const isAboveOrEqualBottom =
      wordTransform[5] >= highlightedParagraph.dimensions.bottom;
    return isBelowOrEqualTop && isAboveOrEqualBottom;
  }
  const currentPage = usePdfStore((s) => s.pageNumber);
  const isCurrentlyViewedPage = currentPage === pageNumber;
  const setIsPdfRendered = usePdfStore((s) => s.setIsPdfRendered);
  const setPageData = usePdfStore((s) => s.setPageData);

  return (
    <Page
      pageNumber={pageNumber}
      key={pageNumber.toString()}
      customTextRenderer={({
        str,

        transform,
      }) => {
        if (
          isHighlighting &&
          isInsideParagraph(transform as Transform)
        ) {
          return `<mark style="background-color: rgb(255,255,204);">${str}</mark>`;
        }

        return str;
      }}
      height={isDualPage ? pdfHeight : undefined}
      width={isDualPage ? undefined : pdfWidth}
      className="rounded shadow-lg"
      renderTextLayer={true}
      renderAnnotationLayer={true}
      canvasBackground="white"
      onGetTextSuccess={(data) => {
        setPageData(pageNumber, data);
      }}
      loading={
        <div className="w-screen bg-white  h-screen grid place-items-center">
          <Loader2 size={20} className="animate-spin" />
        </div>
      }
      onRenderSuccess={() => {
        if (isCurrentlyViewedPage) {
          setIsPdfRendered(bookId, true);
        }
        onRenderComplete?.();
      }}
    />
  );
}
