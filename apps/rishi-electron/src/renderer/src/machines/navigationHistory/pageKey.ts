import { EpubCFI } from 'epubjs'
import type { PositionDescriptor } from './types'

export function pageKey(position: PositionDescriptor): string {
  if (position.kind === 'pdf') {
    return `pdf:${position.page}`
  }
  const parsed = new EpubCFI(position.cfi)
  const spinePos = (parsed as unknown as { spinePos: number }).spinePos
  return `epub:${spinePos}`
}
