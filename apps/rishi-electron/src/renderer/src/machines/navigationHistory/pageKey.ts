import { EpubCFI } from 'epubjs'
import type { PositionDescriptor } from './types'

export function pageKey(position: PositionDescriptor): string {
  if (position.kind === 'pdf') {
    return `pdf:${position.page}`
  }
  if (position.kind === 'azw3' || position.kind === 'mobi') {
    // AZW3/MOBI store chapter-position strings (not valid EpubCFI input)
    return `${position.kind}:${position.cfi}`
  }
  // EPUB — extract spine position from the CFI. The CFI can be a
  // not-yet-resolved seed value (e.g. the DB's `"1"` placeholder for
  // freshly-imported books, or any stale id that survived format
  // migration) before epubjs publishes its first real `epubcfi(...)`.
  // EpubCFI throws on bad input, and an unhandled throw inside a guard
  // / action puts the navigation-history actor into the `error` status —
  // which silently swallows every subsequent event (JUMP_REQUESTED,
  // POP_BACK, …), so the back-nav pill never appears. Treat non-CFI
  // inputs as a synthetic "unknown spine" bucket instead of throwing.
  if (!position.cfi.startsWith('epubcfi(')) {
    return `epub:raw:${position.cfi}`
  }
  try {
    const parsed = new EpubCFI(position.cfi)
    const spinePos = (parsed as unknown as { spinePos: number }).spinePos
    return `epub:${spinePos}`
  } catch {
    return `epub:raw:${position.cfi}`
  }
}
