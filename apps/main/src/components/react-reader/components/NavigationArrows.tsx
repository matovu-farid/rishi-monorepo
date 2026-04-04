import { type IReactReaderStyle } from "../style";

// Props for NavigationArrows component
export type NavigationArrowsProps = {
  onPrev: () => void;
  onNext: () => void;
  readerStyles: IReactReaderStyle;
};

/**
 * NavigationArrows Component
 * Renders the left and right navigation arrow buttons
 * Used to navigate between pages
 */
export const NavigationArrows = ({
  onPrev,
  onNext,
  readerStyles,
}: NavigationArrowsProps) => {
  return (
    <>
      {/* Previous page arrow button */}
      <button
        style={Object.assign({}, readerStyles.arrow, readerStyles.prev)}
        onClick={onPrev}
        aria-label="Previous page"
      >
        ‹
      </button>

      {/* Next page arrow button */}
      <button
        style={Object.assign({}, readerStyles.arrow, readerStyles.next)}
        onClick={onNext}
        aria-label="Next page"
      >
        ›
      </button>
    </>
  );
};
