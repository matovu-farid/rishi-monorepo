import type { IReactReaderStyle } from '../style'

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
 *
 * Accessibility (#197 / WCAG 2.4.7): the reader-style hides the native
 * outline (`outline: 'none'`) so we apply a visible 2px focus ring via
 * `:focus-visible` using the theme `--ring` token. Tailwind utilities won't
 * reach an inline-styled button reliably, so we mirror the ring via
 * `data-focus-visible` + a small inline style swap on focus/blur.
 */
export const TocToggleButton = ({ expandedToc, toggleToc, readerStyles }: TocToggleButtonProps) => {
  // Inline `:focus-visible` ring — `boxShadow` is the most compatible way to
  // paint a ring around an absolutely-positioned button whose `outline` was
  // intentionally stripped by the upstream style contract.
  const focusableStyle = Object.assign(
    {},
    readerStyles.tocButton,
    expandedToc ? readerStyles.tocButtonExpanded : {}
  )

  return (
    <button
      title="Toggle Table of Contents"
      aria-label="Toggle Table of Contents"
      aria-expanded={expandedToc}
      data-testid="toc-toggle-button"
      className="focus-visible:outline-none focus-visible:[box-shadow:0_0_0_2px_var(--ring)]"
      style={focusableStyle}
      onClick={toggleToc}
    >
      {/* Hamburger icon with two bars */}
      <span style={Object.assign({}, readerStyles.tocButtonBar, readerStyles.tocButtonBarTop)} />
      <span style={Object.assign({}, readerStyles.tocButtonBar, readerStyles.tocButtonBottom)} />
    </button>
  )
}
