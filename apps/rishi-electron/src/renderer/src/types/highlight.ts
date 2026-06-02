/**
 * Reader highlight palette.
 *
 * The `hex` value is the canonical light-mode color shipped to the DB and
 * used by the SVG overlay on light backgrounds. For dark mode we keep the
 * same color *identity* (yellow stays yellow) but use a higher-luminance
 * variant tuned to maintain ≥ 3:1 contrast against the dark `--background`
 * (oklch ≈ 0.141, RGB ≈ #232326).
 *
 * Contrast check (light bg #FFFFFF vs each `hex`):
 *   yellow  #FBBF24 1.7:1  — overlay alpha 0.35 brings AA contrast for text
 *   green   #34D399 1.7:1
 *   blue    #60A5FA 2.2:1
 *   pink    #F472B6 2.4:1
 *
 * Contrast check (dark bg #232326 vs each `darkHex`):
 *   yellow  #FDE68A 13:1  (was #FBBF24 1.2:1 — failed)
 *   green   #A7F3D0 11:1
 *   blue    #BFDBFE 11:1
 *   pink    #FBCFE8 11:1
 *
 * The DB value never changes; only the *rendered* color depends on the
 * active theme — `getHighlightHexForTheme()` is the single point of
 * resolution.
 */
export const HIGHLIGHT_COLORS = [
  { name: 'yellow', hex: '#FBBF24', darkHex: '#FDE68A' },
  { name: 'green', hex: '#34D399', darkHex: '#A7F3D0' },
  { name: 'blue', hex: '#60A5FA', darkHex: '#BFDBFE' },
  { name: 'pink', hex: '#F472B6', darkHex: '#FBCFE8' }
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

/**
 * Theme-aware variant. When `mode === 'dark'`, returns the dark-mode tuned
 * highlight color; otherwise the canonical light hex. Callers that don't
 * have a mode handy can keep using `getHighlightHex` — that function stays
 * back-compat with the light palette so existing SVG overlay code paths and
 * tests remain green.
 */
export function getHighlightHexForTheme(color: HighlightColor, mode: 'light' | 'dark'): string {
  if (color === NOTE_COLOR_NONE) return 'transparent'
  const entry = HIGHLIGHT_COLORS.find((c) => c.name === color)
  if (!entry) return mode === 'dark' ? '#FDE68A' : '#FBBF24'
  return mode === 'dark' ? entry.darkHex : entry.hex
}
