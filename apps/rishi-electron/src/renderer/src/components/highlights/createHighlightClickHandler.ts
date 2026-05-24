import type Rendition from 'epubjs/types/rendition'
import type { HighlightRow } from '@/modules/highlight-storage'
import type { HighlightColor } from '@/types/highlight'
import { computeHighlightClickPosition } from './highlightClickPosition'

export interface InlinePopoverState {
  cfiRange: string
  position: { x: number; y: number }
  currentColor: HighlightColor
  hasNote: boolean
}

export interface CreateHighlightClickHandlerDeps {
  highlightsByRangeRef: { current: Map<string, HighlightRow> }
  renditionRef: { current: Rendition | null }
  setInlinePopover: (state: InlinePopoverState) => void
  viewport?: { innerWidth: number; innerHeight: number }
}

/**
 * Builds the per-cfiRange click handler that epubjs invokes when a user
 * clicks an existing highlight annotation. Returns a curried function so the
 * same factory can be reused across all highlights.
 *
 * Reads the highlights map and rendition ref at click time (not bind time),
 * so a click on a freshly-created highlight still resolves the row even
 * though the cb was bound before the row was inserted.
 */
export function createHighlightClickHandler(
  deps: CreateHighlightClickHandlerDeps
): (cfiRange: string) => (e?: MouseEvent) => void {
  const { highlightsByRangeRef, renditionRef, setInlinePopover, viewport } = deps
  return (cfiRange: string) => (e?: MouseEvent) => {
    const row = highlightsByRangeRef.current.get(cfiRange)
    if (!row) return
    // `manager` / `visible` aren't on epubjs's public Rendition type — go
    // through unknown so each step is properly typed as possibly-undefined
    // instead of `any` (which makes the no-unnecessary-condition rule blind).
    const rendition = renditionRef.current as unknown as
      | { manager?: { visible?: () => { element?: Element }[] | undefined } }
      | null
    const view = rendition?.manager?.visible?.()?.[0]
    const fallbackIframe = (view?.element?.querySelector('iframe') as HTMLElement | null) ?? null
    const { x, y } = computeHighlightClickPosition(e, fallbackIframe, viewport)
    setInlinePopover({
      cfiRange,
      position: { x, y },
      currentColor: row.color as HighlightColor,
      hasNote: row.note.trim().length > 0
    })
  }
}
