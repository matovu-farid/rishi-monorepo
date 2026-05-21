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
  // EPUB — extract spine position from the CFI
  const parsed = new EpubCFI(position.cfi)
  const spinePos = (parsed as unknown as { spinePos: number }).spinePos
  return `epub:${spinePos}`
}
