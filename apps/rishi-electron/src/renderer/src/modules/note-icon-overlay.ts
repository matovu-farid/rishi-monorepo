/**
 * NoteIconOverlay — injects small "note exists here" icons into the EPUB
 * iframe document at the top-right of each highlight with a non-empty note.
 *
 * Apple Books shows a margin icon at the line of the note. EPUB rendered
 * via epubjs has no margin gutter (paginated columns fill the iframe), so
 * we anchor inside the iframe content area at the last bounding rect of
 * the noted range — visually "after" the text on its last line.
 *
 * This module is framework-free on purpose:
 *   - No React (avoids dragging a renderer into the iframe document).
 *   - No epubjs (CFI → DOM Range resolution is injected via `resolveRange`,
 *     keeping the module unit-testable with simple Range stubs).
 *
 * Lifecycle is controlled by the caller (EpubView):
 *   1. construct once per rendition view
 *   2. call `render(rows)` after every highlights mutation and on rendition
 *      `relocated` / `rendered` / `resized` events
 *   3. call `destroy()` on unmount or before swapping iframes
 */

export const NOTE_ICON_ATTR = 'data-note-icon-cfi'
const ICON_SIZE = 18
const SVG_NS = 'http://www.w3.org/2000/svg'

export interface NoteRow {
  cfiRange: string
  note: string
}

export interface NoteIconOverlayDeps {
  iframeDoc: Document
  resolveRange: (cfiRange: string) => Range | null
  onIconClick: (cfiRange: string) => void
}

export class NoteIconOverlay {
  /** Public so callers can identity-check against the current iframe doc and recreate the overlay when the iframe is swapped. */
  readonly iframeDoc: Document
  private readonly resolveRange: (cfiRange: string) => Range | null
  private readonly onIconClick: (cfiRange: string) => void

  constructor(deps: NoteIconOverlayDeps) {
    this.iframeDoc = deps.iframeDoc
    this.resolveRange = deps.resolveRange
    this.onIconClick = deps.onIconClick
  }

  render(rows: Iterable<NoteRow>): void {
    this.destroy()
    for (const row of rows) {
      if (!row.note || row.note.trim().length === 0) continue
      const range = this.resolveRange(row.cfiRange)
      if (!range) continue
      const rects = range.getClientRects()
      if (!rects || rects.length === 0) continue
      // Anchor to the LAST rect — for multi-line ranges this is the bottom
      // line, mirroring Apple Books' end-of-text anchor.
      const rect = rects[rects.length - 1]
      this.iframeDoc.body.appendChild(this.makeButton(row.cfiRange, rect))
    }
  }

  destroy(): void {
    const existing = this.iframeDoc.querySelectorAll(`[${NOTE_ICON_ATTR}]`)
    existing.forEach((el) => el.parentNode?.removeChild(el))
  }

  private makeButton(cfiRange: string, rect: Pick<DOMRect, 'top' | 'right'>): HTMLButtonElement {
    const btn = this.iframeDoc.createElement('button')
    btn.setAttribute(NOTE_ICON_ATTR, cfiRange)
    btn.setAttribute('type', 'button')
    btn.setAttribute('aria-label', 'View note')
    btn.setAttribute('title', 'View note')
    btn.appendChild(this.makeIcon())
    Object.assign(btn.style, {
      position: 'absolute',
      top: `${rect.top}px`,
      left: `${rect.right - ICON_SIZE}px`,
      width: `${ICON_SIZE}px`,
      height: `${ICON_SIZE}px`,
      padding: '0',
      margin: '0',
      border: 'none',
      background: 'rgba(96, 165, 250, 0.15)',
      borderRadius: '4px',
      color: '#2563eb',
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      zIndex: '10'
    } satisfies Partial<CSSStyleDeclaration>)
    btn.addEventListener('click', (e) => {
      e.stopPropagation()
      this.onIconClick(cfiRange)
    })
    return btn
  }

  /**
   * Builds the MessageSquareText icon (lucide-react's path data) via DOM
   * APIs rather than innerHTML so no string parsing or sanitization is
   * involved.
   */
  private makeIcon(): SVGSVGElement {
    const svg = this.iframeDoc.createElementNS(SVG_NS, 'svg')
    svg.setAttribute('width', '14')
    svg.setAttribute('height', '14')
    svg.setAttribute('viewBox', '0 0 24 24')
    svg.setAttribute('fill', 'none')
    svg.setAttribute('stroke', 'currentColor')
    svg.setAttribute('stroke-width', '2.5')
    svg.setAttribute('stroke-linecap', 'round')
    svg.setAttribute('stroke-linejoin', 'round')
    for (const d of [
      'M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z',
      'M7 9h10',
      'M7 13h6'
    ]) {
      const path = this.iframeDoc.createElementNS(SVG_NS, 'path')
      path.setAttribute('d', d)
      svg.appendChild(path)
    }
    return svg
  }
}
