export const HIGHLIGHT_COLORS = [
  { name: 'yellow', hex: '#FBBF24' },
  { name: 'green', hex: '#34D399' },
  { name: 'blue', hex: '#60A5FA' },
  { name: 'pink', hex: '#F472B6' }
] as const

/**
 * Sentinel `color` value for note-only highlights — rows that exist only
 * to anchor a note to a CFI range, with no colored SVG overlay. The DB
 * column is `NOT NULL`, so we use a string sentinel rather than null.
 */
export const NOTE_COLOR_NONE = 'none' as const

export type HighlightColor = (typeof HIGHLIGHT_COLORS)[number]['name'] | typeof NOTE_COLOR_NONE

export function isNoteOnly(row: { color: string }): boolean {
  return row.color === NOTE_COLOR_NONE
}

export function getHighlightHex(color: HighlightColor): string {
  if (color === NOTE_COLOR_NONE) return 'transparent'
  return HIGHLIGHT_COLORS.find((c) => c.name === color)?.hex ?? '#FBBF24'
}
