/**
 * CSS injected into the AZW3 iframe document on load. Goals:
 *
 *  - `padding-top: 3rem` keeps the first line of body text clear of the
 *    macOS hiddenInset traffic-light cluster (sits ~28px from window top).
 *  - `height/width: 100vh/100vw` + `column-fill: auto` locks the body to a
 *    single viewport. When the chapter content overflows vertically, the
 *    column algorithm creates *new columns to the right* instead of growing
 *    the page — which means we can paginate horizontally by translating
 *    `scrollLeft` in viewport-sized steps (epub.js / foliate-paginator
 *    style). `column-count: 2` then gives us two columns per viewport.
 *  - `overflow: hidden` on the body suppresses native scrollbars; the
 *    renderer drives `scrollLeft` programmatically.
 *  - `.rishi-tts-active` is the highlight class toggled on the active
 *    paragraph as TTS reads. Background and rounded edges keep it readable
 *    in both light and dark themes.
 */
export const READER_STYLE_ID = 'rishi-azw3-reader-styles'

export const READER_CSS = `
  html, body {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
  }
  body {
    /* Fixed viewport so column-fill: auto creates new columns horizontally
       when content overflows vertically. */
    height: 100vh;
    width: 100vw;
    overflow: hidden;
    /* Two columns per viewport. column-fill: auto keeps columns filling
       sequentially (column 1 fills first, then column 2, then a new pair
       to the right) rather than balancing their heights. */
    column-count: 2;
    column-gap: 2.5rem;
    column-fill: auto;
    padding: 3rem 2.25rem 1.5rem 2.25rem;
  }
  /* Some KF8 books wrap the whole chapter in a single <div>. Without this,
     CSS columns treat the wrapper as one block and can't split it, so the
     content stays jammed into a single column. Forcing display:contents
     collapses the wrapper into the flowing children. */
  body > div:only-child {
    display: contents;
  }
  /* Keep images, figures, tables, and code blocks intact instead of slicing
     them across columns. */
  img, figure, picture, table, pre {
    break-inside: avoid-column;
    max-width: 100%;
    height: auto;
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
