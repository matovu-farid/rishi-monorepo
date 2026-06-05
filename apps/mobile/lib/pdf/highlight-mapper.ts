import type { HighlightShape } from '@/components/pdf/HighlightOverlay'

interface HighlightRow {
  id: string
  cfiRange: string
  color: string
  isDeleted?: boolean | number
}

interface PdfLocator {
  page: number
  rects: Array<{ x: number; y: number; w: number; h: number }>
}

/**
 * Parses a row from the `highlights` table into the shape that
 * <HighlightOverlay> expects. Returns null for EPUB highlights (the
 * cfiRange doesn't start with `pdf:`) or for parse failures.
 */
export function toHighlightShape(row: HighlightRow): HighlightShape | null {
  if (row.isDeleted) return null
  if (!row.cfiRange.startsWith('pdf:')) return null
  let parsed: PdfLocator
  try {
    parsed = JSON.parse(row.cfiRange.slice('pdf:'.length))
  } catch {
    return null
  }
  if (typeof parsed.page !== 'number' || !Array.isArray(parsed.rects)) return null

  const color = (['yellow', 'green', 'blue', 'pink'] as const).includes(row.color as any)
    ? (row.color as HighlightShape['color'])
    : 'yellow'

  return {
    id: row.id,
    page: parsed.page,
    color,
    rects: parsed.rects,
  }
}
