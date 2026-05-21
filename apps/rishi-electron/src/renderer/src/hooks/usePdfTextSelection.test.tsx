import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePdfTextSelection, type PdfSelectionEvent } from './usePdfTextSelection'
import type { ViewportLike } from '@/modules/pdf-locator'

function setupPage(opts: { pageNumber: number; rect: { left: number; top: number; width: number; height: number } }) {
  const page = document.createElement('div')
  page.className = 'react-pdf__Page'
  page.setAttribute('data-page-number', String(opts.pageNumber))
  Object.defineProperty(page, 'getBoundingClientRect', {
    value: () => ({
      left: opts.rect.left, top: opts.rect.top,
      right: opts.rect.left + opts.rect.width, bottom: opts.rect.top + opts.rect.height,
      width: opts.rect.width, height: opts.rect.height, x: opts.rect.left, y: opts.rect.top,
      toJSON() { return this }
    })
  })
  const text = document.createTextNode('hello world')
  page.appendChild(text)
  return { page, text }
}

function makeViewport(scale = 1): ViewportLike {
  return {
    width: 400 * scale, height: 600 * scale, scale,
    convertToViewportPoint(x, y) { return [x * scale, (600 - y) * scale] },
    convertToPdfPoint(x, y) { return [x / scale, 600 - y / scale] }
  }
}

describe('usePdfTextSelection', () => {
  let container: HTMLDivElement
  let containerRef: { current: HTMLDivElement | null }
  // Typed as the actual callback shapes so TypeScript is satisfied at call sites.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let onSelect: ((sel: PdfSelectionEvent) => void) & { mock: any }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let onClear: (() => void) & { mock: any }

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    containerRef = { current: container }
    onSelect = vi.fn() as unknown as ((sel: PdfSelectionEvent) => void) & { mock: any }
    onClear = vi.fn() as unknown as (() => void) & { mock: any }
  })

  afterEach(() => {
    document.body.removeChild(container)
    window.getSelection()?.removeAllRanges()
  })

  it('fires onSelect with locator and anchorPos when mouseup completes a non-collapsed selection on a single page', () => {
    const { page, text } = setupPage({ pageNumber: 4, rect: { left: 0, top: 0, width: 400, height: 600 } })
    container.appendChild(page)

    renderHook(() =>
      usePdfTextSelection({
        containerRef,
        getPageElement: (n) => (n === 4 ? page : null),
        getViewport: () => makeViewport(1),
        onSelect, onClear
      })
    )

    const range = document.createRange()
    range.setStart(text, 0)
    range.setEnd(text, 5)
    Object.defineProperty(range, 'getClientRects', {
      value: () => [{ left: 5, top: 10, width: 60, height: 14, right: 65, bottom: 24 }]
    })
    const sel = window.getSelection()!
    sel.removeAllRanges()
    sel.addRange(range)

    act(() => {
      container.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: 30, clientY: 20 }))
    })

    expect(onSelect).toHaveBeenCalledTimes(1)
    const arg = onSelect.mock.calls[0][0]
    expect(arg.locator.page).toBe(4)
    expect(arg.locator.rects[0].w).toBeGreaterThan(0)
    expect(arg.anchorPos).toMatchObject({ x: expect.any(Number), y: expect.any(Number) })
  })

  it('ignores cross-page selections', () => {
    const a = setupPage({ pageNumber: 1, rect: { left: 0, top: 0, width: 400, height: 600 } })
    const b = setupPage({ pageNumber: 2, rect: { left: 0, top: 700, width: 400, height: 600 } })
    container.appendChild(a.page); container.appendChild(b.page)
    renderHook(() => usePdfTextSelection({
      containerRef,
      getPageElement: (n) => (n === 1 ? a.page : b.page),
      getViewport: () => makeViewport(1),
      onSelect, onClear
    }))
    const range = document.createRange()
    range.setStart(a.text, 0)
    range.setEnd(b.text, 5)
    Object.defineProperty(range, 'getClientRects', { value: () => [
      { left: 0, top: 0, width: 50, height: 14, right: 50, bottom: 14 }
    ]})
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    act(() => container.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })))
    expect(onSelect).not.toHaveBeenCalled()

    // Positive control: collapse the selection onto page 1 only and re-fire
    // mouseup. If the previous bail was caused by an unrelated regression
    // (broken findPageInfo, mismatched getPageElement, null getViewport, or
    // null locator) rather than the cross-page guard, this single-page
    // selection would also fail to fire onSelect.
    const singlePageRange = document.createRange()
    singlePageRange.setStart(a.text, 0)
    singlePageRange.setEnd(a.text, 5)
    Object.defineProperty(singlePageRange, 'getClientRects', { value: () => [
      { left: 0, top: 0, width: 50, height: 14, right: 50, bottom: 14 }
    ]})
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(singlePageRange)
    act(() => container.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })))
    expect(onSelect).toHaveBeenCalledTimes(1)
    expect(onSelect.mock.calls[0][0].locator.page).toBe(1)
  })

  it('fires onClear when selection becomes collapsed', () => {
    renderHook(() => usePdfTextSelection({
      containerRef,
      getPageElement: () => null, getViewport: () => null,
      onSelect, onClear
    }))
    act(() => {
      window.getSelection()!.removeAllRanges()
      document.dispatchEvent(new Event('selectionchange'))
    })
    expect(onClear).toHaveBeenCalled()
  })
})
