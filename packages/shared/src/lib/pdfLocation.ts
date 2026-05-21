/**
 * PDF book.location is a string. Two formats are accepted:
 *   "5"      — page index only (legacy; sub-page offset is lost on restore)
 *   "5:120"  — page index + sub-page scroll offset in pixels
 *
 * Bare "5" still parses cleanly so existing book rows keep restoring to the
 * top of their saved page. New saves always emit "page:offset" (offset is
 * 0 if the user is at the page top), so a roundtrip preserves both axes.
 */
export type PdfLocation = { page: number; offset: number }

export function parsePdfLocation(loc: string | null | undefined): PdfLocation {
  if (!loc) return { page: 0, offset: 0 }
  const parts = loc.split(':') as (string | undefined)[]
  const page = Number.parseInt(parts[0] ?? '', 10)
  const offset = Number.parseInt(parts[1] ?? '', 10)
  return {
    page: Number.isFinite(page) && page > 0 ? page : 0,
    offset: Number.isFinite(offset) && offset > 0 ? offset : 0
  }
}

export function formatPdfLocation(loc: PdfLocation): string {
  const offset = Math.max(0, Math.round(loc.offset))
  return `${loc.page}:${offset}`
}
