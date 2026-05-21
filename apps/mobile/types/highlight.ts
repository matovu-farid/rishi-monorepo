/**
 * Mobile highlight types. Re-exports the canonical color enum +
 * helpers from `@rishi/shared/types/highlight` (Batch 7 polish for
 * G10) so both clients agree on the palette and the per-color hex
 * mapping.
 *
 * The `Highlight` shape mobile uses for its UI is a strict subset of
 * the row that lives in the SQLite `highlights` table — the sync
 * columns (`userId`, `syncVersion`, `isDirty`, `isDeleted`) are
 * stripped by `mapRowToHighlight` in `lib/highlight-storage.ts`.
 *
 * Note: the shared `HighlightColor` type adds `NOTE_COLOR_NONE` ('none')
 * for note-only highlights. Mobile keeps the strict color enum (no
 * note-only) for now — when the schema migration lands to add a
 * `format`/`note-only` column, switch to the wider shared type.
 */
import {
  HIGHLIGHT_COLORS as SHARED_HIGHLIGHT_COLORS,
  getHighlightHex as sharedGetHighlightHex,
} from '@rishi/shared/types/highlight'

// Mobile UI restricts to the 4-color palette (note-only is not surfaced).
export type HighlightColor = 'yellow' | 'green' | 'blue' | 'pink'

export interface Highlight {
  id: string
  bookId: string
  cfiRange: string
  text: string
  color: HighlightColor
  note: string | null
  chapter: string | null
  createdAt: number
  updatedAt: number
}

/**
 * Color palette — same 4 colors as electron, materialized as an array
 * so the UI can iterate it in a stable order. Sourced from
 * `@rishi/shared/types/highlight.HIGHLIGHT_COLORS` so both clients
 * agree on the hex codes.
 */
export const HIGHLIGHT_COLORS: { name: HighlightColor; hex: string }[] =
  SHARED_HIGHLIGHT_COLORS.map((c) => ({ name: c.name as HighlightColor, hex: c.hex }))

export const HIGHLIGHT_OPACITY = 0.3

/**
 * Return the hex code for a HighlightColor, with `yellow` as the
 * fallback if the color value isn't a known mobile palette entry.
 * Wraps the shared helper (which accepts the wider `'none'` variant)
 * and re-narrows to the mobile palette.
 */
export function getHighlightHex(color: HighlightColor): string {
  // The shared helper accepts `'none'` too; mobile callers can't
  // construct that, so the result is always a real hex.
  return sharedGetHighlightHex(color)
}
