/**
 * Typed bridge protocol between the PDF WebView and the React Native host.
 *
 * The WebView hosts pdfjs and renders a scrolling page list. RN owns the
 * UI chrome (toolbar, TOC drawer, annotation popover) and the database.
 * All communication crosses the postMessage boundary as JSON strings, so
 * keeping the shapes typed and pure here lets us unit-test the protocol
 * without booting a WebView.
 *
 * Conventions:
 *   - `pageNumber` is 1-indexed (matches pdfjs `getPage(n)`).
 *   - `locator.rects` are PDF-space coords (origin bottom-left) — see
 *     `@rishi/shared/types/pdf-locator` for the type.
 *   - All requests carry a string `requestId` so async responses can be
 *     correlated by the RN side.
 */

import type { PdfLocator } from '@rishi/shared/types/pdf-locator'

// ---------- WebView → RN ----------

export type PdfReady = { type: 'ready' }

export type PdfLoaded = {
  type: 'loaded'
  numPages: number
  outline: PdfOutlineItem[]
}

export interface PdfOutlineItem {
  /** Display title. */
  title: string
  /** Resolved 1-based page number, or null if the destination couldn't be resolved. */
  pageNumber: number | null
  /** Nested child entries (rare but used by legal/textbook PDFs). */
  children: PdfOutlineItem[]
}

export type PdfPageChanged = {
  type: 'pageChanged'
  pageNumber: number
  /** Sub-page scroll offset in pixels. */
  offset: number
}

export type PdfSelection = {
  type: 'selection'
  pageNumber: number
  /** Selected text. May be the empty string if the WebView couldn't extract it. */
  text: string
  locator: PdfLocator
  /**
   * Screen-space anchor for the annotation popover. Coordinates are
   * WebView-relative pixels — RN must offset them by the WebView's frame.
   */
  anchor: { x: number; y: number }
}

export type PdfSelectionCleared = { type: 'selectionCleared' }

export type PdfPageText = {
  type: 'pageText'
  requestId: string
  pageNumber: number
  /** Paragraphs in reading order. Indexed via `pageNumber * 10000 + i`. */
  paragraphs: Array<{ index: string; text: string }>
}

export type PdfHighlightTapped = {
  type: 'highlightTapped'
  highlightId: string
  anchor: { x: number; y: number }
}

export type PdfError = { type: 'error'; message: string }

export type PdfWebViewOutgoingMessage =
  | PdfReady
  | PdfLoaded
  | PdfPageChanged
  | PdfSelection
  | PdfSelectionCleared
  | PdfPageText
  | PdfHighlightTapped
  | PdfError

// ---------- RN → WebView ----------

export type PdfLoadCommand = {
  type: 'load'
  /** PDF file contents as base64 (no `data:` prefix). */
  data: string
}

export type PdfGoToPageCommand = {
  type: 'goToPage'
  page: number
  /** Sub-page pixel offset (optional). */
  offset?: number
}

export type PdfAddHighlightCommand = {
  type: 'addHighlight'
  id: string
  color: string
  locator: PdfLocator
}

export type PdfRemoveHighlightCommand = {
  type: 'removeHighlight'
  id: string
}

export type PdfSetHighlightsCommand = {
  type: 'setHighlights'
  highlights: Array<{ id: string; color: string; locator: PdfLocator }>
}

export type PdfGetPageTextCommand = {
  type: 'getPageText'
  requestId: string
  pageNumber: number
}

export type PdfHighlightSelectionCommand = {
  type: 'highlightSelection'
  id: string
  color: string
}

export type PdfClearSelectionCommand = { type: 'clearSelection' }

export type PdfWebViewIncomingMessage =
  | PdfLoadCommand
  | PdfGoToPageCommand
  | PdfAddHighlightCommand
  | PdfRemoveHighlightCommand
  | PdfSetHighlightsCommand
  | PdfGetPageTextCommand
  | PdfHighlightSelectionCommand
  | PdfClearSelectionCommand

// ---------- Parsing ----------

/**
 * Parse a raw WebView postMessage payload into a typed outgoing message.
 * Returns null when the payload is malformed or doesn't match the
 * protocol — callers should warn but never throw.
 */
export function parseOutgoing(raw: string): PdfWebViewOutgoingMessage | null {
  let msg: unknown
  try {
    msg = JSON.parse(raw)
  } catch {
    return null
  }
  if (!msg || typeof msg !== 'object') return null
  const type = (msg as { type?: unknown }).type
  if (typeof type !== 'string') return null
  switch (type) {
    case 'ready':
      return { type: 'ready' }
    case 'loaded': {
      const m = msg as Partial<PdfLoaded>
      if (typeof m.numPages !== 'number') return null
      const outline = sanitizeOutline(m.outline ?? [])
      return { type: 'loaded', numPages: m.numPages, outline }
    }
    case 'pageChanged': {
      const m = msg as Partial<PdfPageChanged>
      if (typeof m.pageNumber !== 'number') return null
      const offset = typeof m.offset === 'number' ? m.offset : 0
      return { type: 'pageChanged', pageNumber: m.pageNumber, offset }
    }
    case 'selection': {
      const m = msg as Partial<PdfSelection>
      if (typeof m.pageNumber !== 'number') return null
      if (typeof m.text !== 'string') return null
      if (!m.locator || typeof m.locator !== 'object') return null
      const anchor = m.anchor && typeof m.anchor === 'object' ? m.anchor : { x: 0, y: 0 }
      return {
        type: 'selection',
        pageNumber: m.pageNumber,
        text: m.text,
        locator: m.locator,
        anchor: { x: anchor.x ?? 0, y: anchor.y ?? 0 }
      }
    }
    case 'selectionCleared':
      return { type: 'selectionCleared' }
    case 'pageText': {
      const m = msg as Partial<PdfPageText>
      if (typeof m.requestId !== 'string') return null
      if (typeof m.pageNumber !== 'number') return null
      if (!Array.isArray(m.paragraphs)) return null
      return {
        type: 'pageText',
        requestId: m.requestId,
        pageNumber: m.pageNumber,
        paragraphs: m.paragraphs
      }
    }
    case 'highlightTapped': {
      const m = msg as Partial<PdfHighlightTapped>
      if (typeof m.highlightId !== 'string') return null
      const anchor = m.anchor && typeof m.anchor === 'object' ? m.anchor : { x: 0, y: 0 }
      return {
        type: 'highlightTapped',
        highlightId: m.highlightId,
        anchor: { x: anchor.x ?? 0, y: anchor.y ?? 0 }
      }
    }
    case 'error': {
      const m = msg as Partial<PdfError>
      return { type: 'error', message: typeof m.message === 'string' ? m.message : 'unknown' }
    }
    default:
      return null
  }
}

function sanitizeOutline(input: unknown): PdfOutlineItem[] {
  if (!Array.isArray(input)) return []
  const out: PdfOutlineItem[] = []
  for (const item of input) {
    if (!item || typeof item !== 'object') continue
    const it = item as Partial<PdfOutlineItem>
    if (typeof it.title !== 'string') continue
    out.push({
      title: it.title,
      pageNumber: typeof it.pageNumber === 'number' ? it.pageNumber : null,
      children: sanitizeOutline(it.children ?? [])
    })
  }
  return out
}

/**
 * Serialize an incoming command for postMessage. Pure passthrough today,
 * exposed so the call sites remain typed end-to-end (and so we can wrap
 * it later with logging/retry if needed).
 */
export function serializeIncoming(msg: PdfWebViewIncomingMessage): string {
  return JSON.stringify(msg)
}

/**
 * Flatten a nested outline into a depth-tagged sequence for the TOC
 * drawer UI. Each row carries the original `pageNumber` and a `depth`
 * so the renderer can indent without rebuilding the tree.
 */
export interface FlatOutlineRow {
  title: string
  pageNumber: number | null
  depth: number
}

export function flattenOutline(outline: PdfOutlineItem[], depth = 0): FlatOutlineRow[] {
  const rows: FlatOutlineRow[] = []
  for (const item of outline) {
    rows.push({ title: item.title, pageNumber: item.pageNumber, depth })
    if (item.children.length > 0) {
      rows.push(...flattenOutline(item.children, depth + 1))
    }
  }
  return rows
}
