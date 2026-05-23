import { useEffect, useRef } from 'react'
import { selectionToPdfLocator, type ViewportLike } from '@/modules/pdf-locator'
import type { PdfLocator } from '@/modules/highlight-storage'

export interface PdfSelectionEvent {
  locator: PdfLocator
  anchorPos: { x: number; y: number }
  text: string
}

export interface UsePdfTextSelectionParams {
  containerRef: { current: HTMLElement | null }
  getPageElement: (pageNumber: number) => HTMLElement | null
  getViewport: (pageNumber: number) => ViewportLike | null
  onSelect: (sel: PdfSelectionEvent) => void
  onClear: () => void
}

function findPageInfo(node: Node | null): { el: HTMLElement; pageNumber: number } | null {
  let cur: Node | null = node
  while (cur) {
    if (cur instanceof HTMLElement && cur.classList.contains('react-pdf__Page')) {
      const n = Number(cur.getAttribute('data-page-number') ?? '0')
      if (Number.isFinite(n) && n > 0) return { el: cur, pageNumber: n }
    }
    cur = cur.parentNode
  }
  return null
}

export function usePdfTextSelection(params: UsePdfTextSelectionParams): void {
  const paramsRef = useRef(params)
  paramsRef.current = params

  useEffect(() => {
    const container = params.containerRef.current
    if (!container) return

    const handleMouseUp = (): void => {
      const { onSelect, getPageElement, getViewport } = paramsRef.current
      const sel = window.getSelection()
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return
      const range = sel.getRangeAt(0)
      const startInfo = findPageInfo(range.startContainer)
      const endInfo = findPageInfo(range.endContainer)
      if (!startInfo || startInfo.el !== endInfo?.el) return
      const expectedEl = getPageElement(startInfo.pageNumber)
      if (expectedEl !== startInfo.el) return
      const viewport = getViewport(startInfo.pageNumber)
      if (!viewport) return
      const locator = selectionToPdfLocator(range, startInfo.el, viewport, startInfo.pageNumber)
      if (!locator) return
      // `.at(0)` returns `DOMRect | undefined` regardless of the project's
      // `noUncheckedIndexedAccess` setting — that's what lets the guard below
      // be meaningful (plain `rects[0]` would be typed as `DOMRect` and the
      // guard would be dead).
      const rects = Array.from(range.getClientRects())
      const first = rects.at(0)
      if (!first) return
      onSelect({
        locator,
        anchorPos: { x: first.left + first.width / 2, y: first.top - 8 },
        text: range.toString()
      })
    }

    const handleSelectionChange = (): void => {
      const sel = window.getSelection()
      if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
        paramsRef.current.onClear()
      }
    }

    container.addEventListener('mouseup', handleMouseUp)
    document.addEventListener('selectionchange', handleSelectionChange)
    return () => {
      container.removeEventListener('mouseup', handleMouseUp)
      document.removeEventListener('selectionchange', handleSelectionChange)
    }
  }, [params.containerRef])
}
