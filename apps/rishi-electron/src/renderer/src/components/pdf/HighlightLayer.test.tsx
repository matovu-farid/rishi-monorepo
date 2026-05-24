import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { HighlightLayer } from './HighlightLayer'
import type { HighlightRow } from '@/modules/highlight-storage'
import type { ViewportLike } from '@/modules/pdf-locator'

function makeViewport(scale = 1): ViewportLike {
  return {
    width: 400 * scale,
    height: 600 * scale,
    scale,
    convertToViewportPoint(x, y) {
      return [x * scale, (600 - y) * scale]
    },
    convertToPdfPoint(x, y) {
      return [x / scale, 600 - y / scale]
    }
  }
}

function makeRow(overrides: Partial<HighlightRow> = {}): HighlightRow {
  return {
    id: 'r1',
    bookId: 'b1',
    format: 'pdf',
    cfiRange: null,
    locator: JSON.stringify({ page: 1, rects: [{ x: 10, y: 580, w: 100, h: 15 }] }),
    text: 'hi',
    color: 'yellow',
    note: '',
    chapter: null,
    createdAt: 'now',
    updatedAt: null,
    syncId: null,
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
    ...overrides
  }
}

describe('HighlightLayer', () => {
  it('renders one rect div per highlight rect', () => {
    const rows = [
      makeRow({
        id: 'a',
        locator: JSON.stringify({
          page: 1,
          rects: [
            { x: 0, y: 580, w: 50, h: 15 },
            { x: 0, y: 560, w: 80, h: 15 }
          ]
        })
      }),
      makeRow({ id: 'b' })
    ]
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={rows}
        onHighlightClick={vi.fn()}
      />
    )
    expect(screen.getAllByTestId('pdf-highlight-rect')).toHaveLength(3)
  })

  it('skips highlights whose locator is null, non-JSON, or for a different page', () => {
    const rows = [
      makeRow({ id: 'null-loc', locator: null }),
      makeRow({ id: 'bad-json', locator: '{not json' }),
      makeRow({
        id: 'other-page',
        locator: JSON.stringify({ page: 99, rects: [{ x: 0, y: 0, w: 10, h: 10 }] })
      }),
      makeRow({ id: 'ok' })
    ]
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={rows}
        onHighlightClick={vi.fn()}
      />
    )
    expect(screen.getAllByTestId('pdf-highlight-rect')).toHaveLength(1)
  })

  it('applies row color as a translucent background', () => {
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={[makeRow({ color: 'green' })]}
        onHighlightClick={vi.fn()}
      />
    )
    const rect = screen.getByTestId('pdf-highlight-rect')
    // getHighlightHex('green') === '#34D399'; reported as rgb(52, 211, 153) or rgba(...) in happy-dom.
    expect(rect.style.backgroundColor).toMatch(/52|34/)
  })

  it('invokes onHighlightClick with the row and the mouse event', () => {
    const onClick = vi.fn()
    render(
      <HighlightLayer
        pageNumber={1}
        pageEl={document.createElement('div')}
        viewport={makeViewport(1)}
        highlights={[makeRow({ id: 'clicked' })]}
        onHighlightClick={onClick}
      />
    )
    fireEvent.click(screen.getByTestId('pdf-highlight-rect'))
    expect(onClick).toHaveBeenCalledTimes(1)
    expect(onClick.mock.calls[0][0].id).toBe('clicked')
    expect(onClick.mock.calls[0][1].type).toBe('click')
  })
})
