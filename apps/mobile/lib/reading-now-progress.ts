/**
 * #41 — Library "Reading Now" pill needs a progress subline.
 *
 * Pure formatter consumed by the Reading Now pill on
 * `app/(tabs)/index.tsx`. Returns a format-aware human-readable
 * progress string, or `null` when there is no progress data to show.
 *
 * Format mapping:
 *   - PDF / DJVU  → "Page X of Y" when both `currentPage` and a derivable
 *                   total are known, else "Page X" when only page is set.
 *                   Returns null when neither is set.
 *   - EPUB / MOBI / AZW3 → "X%" from `lastProgressPercent` (a 0..1 float).
 *                          Returns null when no progress has been recorded
 *                          yet (legacy row, never opened post-migration).
 *
 * Boundary behaviour:
 *   - Clamps `lastProgressPercent` into [0, 1] (epubjs sometimes emits
 *     1.0000001 at the spine boundary, and a malformed PDF could divide
 *     to slightly > 1).
 *   - NaN / undefined progress is treated as "no data" (null) so the
 *     pill stays empty rather than rendering "NaN%".
 */

export interface ReadingNowProgressInput {
  format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
  currentPage: number | null
  lastProgressPercent: number | null
}

/**
 * Clamp a 0..1 float into the closed interval, returning null when the
 * value is NaN / undefined / null. Internal helper.
 */
function normalizeProgress(value: number | null | undefined): number | null {
  if (value === null || value === undefined) return null
  if (Number.isNaN(value)) return null
  if (value < 0) return 0
  if (value > 1) return 1
  return value
}

export function formatReadingNowProgress(
  input: ReadingNowProgressInput,
): string | null {
  const { format, currentPage, lastProgressPercent } = input
  const progress = normalizeProgress(lastProgressPercent)

  if (format === 'pdf' || format === 'djvu') {
    // Paginated formats: prefer "Page X of Y" when we can derive Y from
    // (page / percent). Fall back to just "Page X" when only the page
    // is known. Render nothing when neither is recorded.
    if (currentPage !== null && currentPage > 0) {
      if (progress !== null && progress > 0) {
        const total = Math.round(currentPage / progress)
        if (Number.isFinite(total) && total >= currentPage) {
          return `Page ${currentPage} of ${total}`
        }
      }
      return `Page ${currentPage}`
    }
    return null
  }

  // EPUB / MOBI / AZW3: percent-based. epubjs gives us the float
  // directly; MOBI/AZW3 readers compute current/total chapters at save
  // time and store the resulting float here.
  if (progress === null) return null
  return `${Math.round(progress * 100)}%`
}
