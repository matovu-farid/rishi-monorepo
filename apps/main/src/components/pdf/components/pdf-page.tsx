import { Page } from "react-pdf";

import {
  highlightedParagraphAtom,
  isHighlightingAtom,
  pageNumberAtom,
  isPdfRenderedAtom,
  getCurrentViewParagraphsAtom,
  getNextViewParagraphsAtom,
  getPreviousViewParagraphsAtom,
  isTextGotAtom,
  setPageNumberToPageDataAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue, useSetAtom } from "jotai";
import { Loader2 } from "lucide-react";
import { pageDataToParagraphs } from "../utils/getPageParagraphs";
import { PAGE_HEIGHT } from "../utils/constants";

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
  // const [pageData, setPageData] = useState<TextContent | null>(null);
  const isHighlighting = useAtomValue(isHighlightingAtom);

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
  const currentPage = useAtomValue(pageNumberAtom);
  const isCurrentlyViewedPage = currentPage === pageNumber;
  const isNextPage = currentPage === pageNumber + 1;
  const isPreviousPage = currentPage === pageNumber - 1;
  const setCurrentViewParagraphs = useSetAtom(getCurrentViewParagraphsAtom);
  const setNextViewParagraphs = useSetAtom(getNextViewParagraphsAtom);
  const setPreviousViewParagraphs = useSetAtom(getPreviousViewParagraphsAtom);
  const setIsCanvasRendered = useSetAtom(isPdfRenderedAtom);
  const setPageNumberToPageData = useSetAtom(setPageNumberToPageDataAtom);

  const highlightedParagraph = useAtomValue(highlightedParagraphAtom);
  const setIsTextGot = useSetAtom(isTextGotAtom);

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
          // isHighlighedPage() &&
          isInsideParagraph(transform as Transform)
        ) {
          return `<mark style="background-color: rgb(255,255,204);">${str}</mark>`;
        }

        return str;
      }}
      height={isDualPage ? pdfHeight : undefined}
      width={isDualPage ? undefined : pdfWidth}
      className={` rounded shadow-lg  h-[1540px]`}
      renderTextLayer={true}
      renderAnnotationLayer={true}
      canvasBackground="white"
      onGetTextSuccess={(data) => {
        setPageNumberToPageData({
          pageNumber,
          pageData: data,
        });
      }}
      loading={
        <div className="w-screen bg-white  h-screen grid place-items-center">
          <Loader2 size={20} className="animate-spin" />
        </div>
      }
      onRenderSuccess={() => {
        if (isCurrentlyViewedPage) {
          setIsCanvasRendered(bookId, true);
        }
        onRenderComplete?.();
      }}
    />
  );
}
