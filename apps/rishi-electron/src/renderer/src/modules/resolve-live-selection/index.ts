/**
 * Live-selection resolver for the EPUB rendition.
 *
 * The read-aloud-from-selection flow has three trigger surfaces (popover
 * button, ⌘⇧L shortcut, native right-click menu). The popover and shortcut
 * paths populate `useSelectionStore` via the rendition's `selected` event.
 * The right-click path is separate: Electron's native context menu fires on
 * any selection it observes — even when the rendition's `selected` event
 * never fired (closure timing, debounce, programmatic selections, etc.). We
 * therefore need a fallback that queries the iframe's live selection at
 * handler-invocation time and rebuilds a `{cfiRange, text}` pair.
 *
 * This module is intentionally a pure function over the minimal rendition
 * shape it needs so it can be unit-tested without epub.js.
 */

export interface LiveSelection {
  cfiRange: string
  text: string
}

export interface ViewWithSelection {
  contents?: {
    window?: { getSelection?(): Selection | null } | null
    cfiFromRange?(range: Range, ignoreClass?: string): string
  } | null
}

export interface RenditionViews {
  forEach(cb: (view: ViewWithSelection) => void): void
}

export interface RenditionLike {
  manager?: { views?: RenditionViews | null } | null
}

export function resolveLiveSelection(
  rendition: RenditionLike | null | undefined
): LiveSelection | null {
  const views = rendition?.manager?.views
  if (!views) return null

  let result: LiveSelection | null = null
  views.forEach((view) => {
    if (result) return
    const contents = view.contents
    const win = contents?.window
    if (!win || typeof win.getSelection !== 'function') return
    const sel = win.getSelection()
    if (!sel || sel.rangeCount === 0) return
    const text = sel.toString()
    if (!text.trim()) return
    const cfiFn = contents?.cfiFromRange
    if (typeof cfiFn !== 'function') return
    try {
      const range = sel.getRangeAt(0)
      const cfi = cfiFn.call(contents, range)
      result = { cfiRange: cfi, text }
    } catch {
      // cfiFromRange can throw on detached ranges; treat as "no selection".
    }
  })
  return result
}
