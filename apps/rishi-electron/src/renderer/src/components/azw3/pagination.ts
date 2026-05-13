/**
 * Pure helpers for AZW3 viewport-snapped pagination. Kept separate from the
 * renderer component so they can be unit-tested without spinning up jsdom +
 * a fake iframe.
 *
 * The reader now identifies a reading position as `chapterIndex:pageInChapter`
 * — i.e. which section the iframe currently has loaded and which viewport
 * page of CSS columns is scrolled into view. The serialized form is a colon-
 * delimited string for compactness in the books.location column.
 *
 * Legacy reading positions are bare integers (just the chapter index); we
 * accept them and assume page 0 within that chapter so reopening an existing
 * book doesn't reset the reader to the cover.
 */

export interface ReadingPosition {
  chapter: number
  page: number
}

/**
 * Parse a serialized reading position. Accepts the new `"<chapter>:<page>"`
 * format, the legacy bare `"<chapter>"` format, and falls back to
 * `{ chapter: 0, page: 0 }` for empty/malformed input so callers can safely
 * use the result without further validation.
 */
export function parseLocation(raw: string | null | undefined): ReadingPosition {
  if (!raw) return { chapter: 0, page: 0 }
  const parts = raw.split(':')
  const chapter = Number(parts[0])
  const page = parts.length > 1 ? Number(parts[1]) : 0
  return {
    chapter: Number.isFinite(chapter) && chapter >= 0 ? Math.floor(chapter) : 0,
    page: Number.isFinite(page) && page >= 0 ? Math.floor(page) : 0
  }
}

/** Serialize a reading position to the `"<chapter>:<page>"` form. */
export function formatLocation(chapter: number, page: number): string {
  return `${chapter}:${page}`
}

/**
 * Compute the per-page horizontal stride for CSS-column pagination.
 *
 * The stride between pages is NOT just `clientWidth + columnGap` — it
 * also has to subtract the body's horizontal padding because the column
 * flow lives inside the padded content box, not at the body's edges. With
 * `box-sizing: border-box`, the leftmost column starts at `x = paddingLeft`
 * and the rightmost column of any page ends at `x = clientWidth - paddingRight`,
 * leaving `2*paddingX` worth of body width that does NOT advance with each
 * page. The trailing column-gap at the page boundary IS counted toward
 * the advance.
 */
export function computePageStep(
  clientWidth: number,
  columnGap: number,
  paddingLeft = 0,
  paddingRight = 0
): number {
  const step = clientWidth - paddingLeft - paddingRight + columnGap
  return Math.max(1, step)
}

/**
 * Total pages for a column-flowed document. Uses the page-stride model:
 * pages = floor((scrollWidth - clientWidth) / pageStep) + 1.
 * Returns at least 1 even when the content fits in a single page.
 */
export function measurePageCount(
  scrollWidth: number,
  clientWidth: number,
  columnGap: number,
  paddingLeft = 0,
  paddingRight = 0
): number {
  if (clientWidth <= 0) return 1
  const pageStep = computePageStep(clientWidth, columnGap, paddingLeft, paddingRight)
  if (scrollWidth <= clientWidth) return 1
  return Math.floor((scrollWidth - clientWidth) / pageStep) + 1
}
