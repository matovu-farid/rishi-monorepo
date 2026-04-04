import { type CSSProperties } from "react";
import { type NavItem } from "epubjs";
import { type IReactReaderStyle } from "../style";

// Props for individual table of contents items
type TocItemProps = {
  data: NavItem;
  setLocation: (value: string) => void;
  styles?: CSSProperties;
};

/**
 * TocItem Component
 * Recursively renders table of contents entries with their subitems
 * Allows users to click on chapter/section names to navigate
 */
const TocItem = ({ data, setLocation, styles }: TocItemProps) => (
  <div>
    <button onClick={() => setLocation(data.href)} style={styles}>
      {data.label}
    </button>
    {/* Recursively render nested chapters/sections with indentation */}
    {data.subitems && data.subitems.length > 0 && (
      <div style={{ paddingLeft: 10 }}>
        {data.subitems.map((item, i) => (
          <TocItem
            key={i}
            data={item}
            styles={styles}
            setLocation={setLocation}
          />
        ))}
      </div>
    )}
  </div>
);

// Props for TableOfContents component
export type TableOfContentsProps = {
  toc: NavItem[];
  expandedToc: boolean;
  setLocation: (loc: string) => void;
  toggleToc: () => void;
  readerStyles: IReactReaderStyle;
};

/**
 * TableOfContents Component
 * Renders the table of contents sidebar
 * Shows hierarchical list of chapters/sections
 * Includes background overlay that closes TOC when clicked
 */
export const TableOfContents = ({
  toc,
  expandedToc,
  setLocation,
  toggleToc,
  readerStyles,
}: TableOfContentsProps) => {
  return (
    <div>
      <div style={readerStyles.tocArea}>
        <div style={readerStyles.toc}>
          {/* Render each top-level TOC entry (TocItem handles recursion) */}
          {toc.map((item, i) => (
            <TocItem
              data={item}
              key={i}
              setLocation={setLocation}
              styles={readerStyles.tocAreaButton}
            />
          ))}
        </div>
      </div>
      {/* Dark overlay behind TOC that closes it when clicked */}
      {expandedToc && (
        <div style={readerStyles.tocBackground} onClick={toggleToc} />
      )}
    </div>
  );
};
