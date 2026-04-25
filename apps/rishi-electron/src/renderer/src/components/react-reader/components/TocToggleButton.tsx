import { type IReactReaderStyle } from '../style'

// Props for TocToggleButton component
export type TocToggleButtonProps = {
  expandedToc: boolean
  toggleToc: () => void
  readerStyles: IReactReaderStyle
}

/**
 * TocToggleButton Component
 * Renders the TOC toggle button
 * Hamburger-style icon that changes appearance when TOC is open
 * Located at top-left of the reader
 */
export const TocToggleButton = ({ expandedToc, toggleToc, readerStyles }: TocToggleButtonProps) => {
  return (
    <button
      title="Toggle Table of Contents"
      style={Object.assign(
        {},
        readerStyles.tocButton,
        expandedToc ? readerStyles.tocButtonExpanded : {}
      )}
      onClick={toggleToc}
    >
      {/* Hamburger icon with two bars */}
      <span style={Object.assign({}, readerStyles.tocButtonBar, readerStyles.tocButtonBarTop)} />
      <span style={Object.assign({}, readerStyles.tocButtonBar, readerStyles.tocButtonBottom)} />
    </button>
  )
}
