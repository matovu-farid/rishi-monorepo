// Import required CSS for text and annotation layers
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";

import { usePdfStore } from "@/stores/pdfStore";
import { BackgroundPageComponent } from "./background-page";

export function TextExtractor({
  pageWidth,
  pdfHeight,
  isDualPage,
  bookId,
}: {
  pageWidth: number;
  pdfHeight: number;
  isDualPage: boolean;
  bookId: string;
}) {
  const pageNumber = usePdfStore((s) => s.backgroundPage);

  return (
    <div
      style={{
        position: "absolute",
        top: "-9999px",
        left: "-9999px",
      }}
    >
      <BackgroundPageComponent
        key={`extractor-page-${pageNumber}`}
        thispageNumber={pageNumber}
        pdfWidth={pageWidth}
        pdfHeight={pdfHeight}
        isDualPage={isDualPage}
        bookId={bookId}
        onRenderComplete={() => {
          // setTimeout(() => {
          //   setPageNumber((pageNumber) => pageNumber + 1);
          // }, 1000);
        }}
      />
    </div>
  );
}
