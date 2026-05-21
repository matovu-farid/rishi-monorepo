/**
 * PDF-space coordinate locator for a highlight or selection. Rectangles
 * are stored in PDF coordinates (origin bottom-left, Y grows up) so they
 * survive zoom and viewport size changes — the renderer projects them
 * back to screen space via pdfjs's viewport at render time.
 *
 * `page` is 1-indexed (matches pdfjs `getPage(n)` and electron's
 * `react-pdf` page numbers).
 *
 * This shape is identical on electron (via window.electron.highlightsSave
 * `locator` JSON column) and mobile (via the cfiRange `pdf:` prefix +
 * JSON payload in the highlights table) so the same row syncs to D1 and
 * deserializes on either client.
 */
export interface PdfLocator {
  page: number
  rects: Array<{ x: number; y: number; w: number; h: number }>
}

/** Encode a PdfLocator into a stable string for storage / IPC. */
export function encodePdfLocator(loc: PdfLocator): string {
  return JSON.stringify(loc)
}

/** Decode a stored PdfLocator string. Returns null on invalid input. */
export function decodePdfLocator(s: string | null | undefined): PdfLocator | null {
  if (!s) return null
  try {
    const parsed = JSON.parse(s) as PdfLocator
    if (typeof parsed.page !== 'number') return null
    if (!Array.isArray(parsed.rects)) return null
    for (const r of parsed.rects) {
      if (
        typeof r.x !== 'number' ||
        typeof r.y !== 'number' ||
        typeof r.w !== 'number' ||
        typeof r.h !== 'number'
      ) {
        return null
      }
    }
    return parsed
  } catch {
    return null
  }
}

/**
 * Mobile-only convention: PDF highlights are stored in the same
 * `highlights` table as EPUB ones (shared with D1). The `cfiRange` column
 * is reused for the encoded PdfLocator, prefixed with `pdf:` so callers
 * can distinguish formats without a schema migration.
 *
 *   `pdf:{"page":5,"rects":[{"x":72,"y":120,"w":300,"h":12}]}`
 *
 * Electron stores the format in a separate `format` column and the
 * locator in a `locator` column — both shapes are deserializable to the
 * same `PdfLocator`, so a row written by either client renders on the
 * other after sync.
 */
export const PDF_CFI_PREFIX = 'pdf:'

export function encodePdfCfiRange(loc: PdfLocator): string {
  return `${PDF_CFI_PREFIX}${encodePdfLocator(loc)}`
}

export function decodePdfCfiRange(cfiRange: string): PdfLocator | null {
  if (!cfiRange.startsWith(PDF_CFI_PREFIX)) return null
  return decodePdfLocator(cfiRange.slice(PDF_CFI_PREFIX.length))
}

export function isPdfCfiRange(cfiRange: string): boolean {
  return cfiRange.startsWith(PDF_CFI_PREFIX)
}
