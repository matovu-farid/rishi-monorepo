export interface ParagraphWithCFI {
  text: string
  cfiRange: string
}

export type { Conversation } from './conversation'
export type { HighlightColor } from './highlight'
export { HIGHLIGHT_COLORS, getHighlightHex } from './highlight'
