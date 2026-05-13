/**
 * CSS injected into the AZW3 iframe document on load. Goals:
 *
 *  - `padding-top: 3rem` keeps the first line of body text clear of the
 *    macOS hiddenInset traffic-light cluster (sits ~28px from window top).
 *  - `column-count: 2` mirrors the EPUB reader's two-column layout for a
 *    consistent reading rhythm. Collapses to one column under 768px so the
 *    UX stays usable when the user shrinks the window.
 *  - `.rishi-tts-active` is the highlight class toggled on the active
 *    paragraph as TTS reads. Background and rounded edges keep it readable
 *    in both light and dark themes.
 */
export const READER_STYLE_ID = 'rishi-azw3-reader-styles'

export const READER_CSS = `
  html, body {
    box-sizing: border-box;
    max-width: 100%;
  }
  body {
    column-count: 2;
    column-gap: 2.5rem;
    column-rule: 1px solid rgba(127, 127, 127, 0.15);
    padding: 3rem 2.25rem 1.5rem 2.25rem;
    overflow-x: hidden;
  }
  body > *, body > * > * {
    break-inside: avoid-column;
  }
  .rishi-tts-active {
    background-color: rgba(255, 224, 102, 0.45);
    border-radius: 3px;
    padding: 1px 2px;
    box-decoration-break: clone;
    -webkit-box-decoration-break: clone;
    transition: background-color 180ms ease;
  }
  @media (max-width: 768px) {
    body { column-count: 1; }
  }
`

/**
 * Idempotently inject the reader stylesheet into the given document. Safe to
 * call repeatedly — replaces existing rules if the element already exists.
 * Returns the style element for tests.
 */
export function injectReaderStyles(doc: Document): HTMLStyleElement | null {
  if (!doc?.head) return null
  let style = doc.getElementById(READER_STYLE_ID) as HTMLStyleElement | null
  if (!style) {
    style = doc.createElement('style')
    style.id = READER_STYLE_ID
    doc.head.appendChild(style)
  }
  style.textContent = READER_CSS
  return style
}
