import { describe, it, expect, vi } from 'vitest'
import { createHighlightClickHandler } from './createHighlightClickHandler'
import type { HighlightRow } from '@/modules/highlight-storage'

function row(over: Partial<HighlightRow> = {}): HighlightRow {
  return {
    id: 'h1',
    bookId: 'b1',
    format: 'epub',
    cfiRange: 'cfi:/6/8!/4/2,/1:0,/1:5',
    locator: null,
    text: 'sample',
    color: 'yellow',
    note: '',
    chapter: null,
    createdAt: '0',
    updatedAt: 0,
    syncId: null,
    syncVersion: 0,
    isDirty: 1,
    isDeleted: 0,
    ...over
  } as HighlightRow
}

function makeIframe(rect: Partial<DOMRect>): HTMLElement {
  return {
    getBoundingClientRect: () => ({ left: 0, top: 0, ...rect }) as DOMRect,
    querySelector: () => null
  } as unknown as HTMLElement
}

function makeView(iframe: HTMLElement | null) {
  return {
    element: iframe
      ? ({ querySelector: () => iframe } as unknown as HTMLDivElement)
      : undefined
  }
}

describe('createHighlightClickHandler', () => {
  it('opens the inline popover with the row color when the row is in the map', () => {
    const setInlinePopover = vi.fn()
    const map = new Map<string, HighlightRow>()
    const r = row({ color: 'green' })
    map.set(r.cfiRange!, r)

    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: { manager: { visible: () => [makeView(null)] } } as never },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    handler(r.cfiRange!)(undefined)

    expect(setInlinePopover).toHaveBeenCalledTimes(1)
    expect(setInlinePopover).toHaveBeenCalledWith({
      cfiRange: r.cfiRange,
      position: { x: 500, y: 400 },
      currentColor: 'green',
      hasNote: false
    })
  })

  it('sets hasNote=true when the row has a non-empty note', () => {
    const setInlinePopover = vi.fn()
    const map = new Map<string, HighlightRow>()
    const r = row({ note: 'a thought' })
    map.set(r.cfiRange!, r)

    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: null },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    handler(r.cfiRange!)(undefined)
    expect(setInlinePopover).toHaveBeenCalledWith(expect.objectContaining({ hasNote: true }))
  })

  it('treats whitespace-only notes as no note (hasNote=false)', () => {
    const setInlinePopover = vi.fn()
    const r = row({ note: '   \n  ' })
    const map = new Map<string, HighlightRow>([[r.cfiRange!, r]])

    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: null },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    handler(r.cfiRange!)(undefined)
    expect(setInlinePopover).toHaveBeenCalledWith(expect.objectContaining({ hasNote: false }))
  })

  it('is a no-op when the cfiRange is not in the map (does not open popover)', () => {
    const setInlinePopover = vi.fn()
    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: new Map() },
      renditionRef: { current: null },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    handler('cfi:not-there')(undefined)

    expect(setInlinePopover).not.toHaveBeenCalled()
  })

  it('uses iframe-translated coords from the event when available', () => {
    const setInlinePopover = vi.fn()
    const iframe = makeIframe({ left: 40, top: 60 })
    const r = row()
    const map = new Map([[r.cfiRange!, r]])

    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: { manager: { visible: () => [makeView(iframe)] } } as never },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    // Event target has no frameElement; helper falls back to view's iframe.
    const e = {
      target: { ownerDocument: { defaultView: {} } } as unknown as Element,
      clientX: 150,
      clientY: 90
    } as unknown as MouseEvent

    handler(r.cfiRange!)(e)

    expect(setInlinePopover).toHaveBeenCalledWith({
      cfiRange: r.cfiRange,
      position: { x: 190, y: 150 },
      currentColor: 'yellow',
      hasNote: false
    })
  })

  it('captures cfiRange per-invocation (different handlers for different ranges)', () => {
    const setInlinePopover = vi.fn()
    const a = row({ id: 'A', cfiRange: 'cfi:A', color: 'blue' })
    const b = row({ id: 'B', cfiRange: 'cfi:B', color: 'pink' })
    const map = new Map<string, HighlightRow>([
      [a.cfiRange!, a],
      [b.cfiRange!, b]
    ])

    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: null },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    handler(b.cfiRange!)(undefined)
    expect(setInlinePopover).toHaveBeenLastCalledWith(
      expect.objectContaining({ cfiRange: 'cfi:B', currentColor: 'pink' })
    )

    handler(a.cfiRange!)(undefined)
    expect(setInlinePopover).toHaveBeenLastCalledWith(
      expect.objectContaining({ cfiRange: 'cfi:A', currentColor: 'blue' })
    )
  })

  it('reads the map at click time (works after row was added post-binding)', () => {
    // This is the "freshly created highlight" case: cb is bound before the
    // row is in the map, then row is added, then click fires.
    const setInlinePopover = vi.fn()
    const map = new Map<string, HighlightRow>()
    const handler = createHighlightClickHandler({
      highlightsByRangeRef: { current: map },
      renditionRef: { current: null },
      setInlinePopover,
      viewport: { innerWidth: 1000, innerHeight: 800 }
    })

    const cb = handler('cfi:late')
    // Row added AFTER cb was created — the handler must still find it.
    map.set('cfi:late', row({ cfiRange: 'cfi:late', color: 'pink' }))

    cb(undefined)
    expect(setInlinePopover).toHaveBeenCalledWith(
      expect.objectContaining({ cfiRange: 'cfi:late', currentColor: 'pink' })
    )
  })
})
