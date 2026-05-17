import { useMemo, type MouseEvent as ReactMouseEvent } from 'react'
import type { JSX } from 'react'
import { pdfLocatorToScreenRects, type ViewportLike } from '@/modules/pdf-locator'
import type { HighlightRow, PdfLocator } from '@/modules/highlight-storage'
import { getHighlightHex, type HighlightColor } from '@/types/highlight'

interface HighlightLayerProps {
  pageNumber: number
  pageEl: HTMLElement
  viewport: ViewportLike
  highlights: HighlightRow[]
  onHighlightClick: (row: HighlightRow, event: ReactMouseEvent<HTMLDivElement>) => void
}

function parseLocator(json: string | null): PdfLocator | null {
  if (!json) return null
  try {
    const parsed = JSON.parse(json) as PdfLocator
    if (typeof parsed.page !== 'number' || !Array.isArray(parsed.rects)) return null
    return parsed
  } catch {
    return null
  }
}

function hexWithAlpha(hex: string, alpha: number): string {
  if (!/^#[0-9a-f]{6}$/i.test(hex)) return 'transparent'
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

export function HighlightLayer({
  pageNumber, pageEl, viewport, highlights, onHighlightClick
}: HighlightLayerProps): JSX.Element {
  const rendered = useMemo(() => {
    const items: Array<{
      key: string
      row: HighlightRow
      rect: { left: number; top: number; width: number; height: number }
    }> = []
    for (const row of highlights) {
      const loc = parseLocator(row.locator)
      if (!loc || loc.page !== pageNumber) continue
      const screenRects = pdfLocatorToScreenRects(loc, pageEl, viewport)
      screenRects.forEach((rect, idx) => {
        items.push({ key: `${row.id}:${idx}`, row, rect })
      })
    }
    return items
  }, [highlights, pageNumber, pageEl, viewport])

  return (
    <div
      data-testid="pdf-highlight-layer"
      style={{ position: 'absolute', inset: 0, pointerEvents: 'none', zIndex: 2 }}
    >
      {rendered.map(({ key, row, rect }) => (
        <div
          key={key}
          data-testid="pdf-highlight-rect"
          data-highlight-id={row.id}
          onClick={(e) => onHighlightClick(row, e)}
          style={{
            position: 'absolute',
            left: rect.left, top: rect.top, width: rect.width, height: rect.height,
            backgroundColor: hexWithAlpha(getHighlightHex(row.color as HighlightColor), 0.35),
            pointerEvents: 'auto',
            cursor: 'pointer'
          }}
        />
      ))}
    </div>
  )
}
