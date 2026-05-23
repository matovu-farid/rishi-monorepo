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
 *                          Returns null when no progress recorded yet.
 *
 * Boundary behaviour:
 *   - Clamps `lastProgressPercent` into [0, 1] (epubjs sometimes emits
 *     1.0000001 at the spine boundary).
 *   - NaN / undefined progress is treated as "no data" (null).
 *
 * Stub for the red commit: returns null for every input so the test
 * assertions fail with real comparisons rather than module-not-found
 * errors. The green commit replaces this with the real implementation.
 */

export interface ReadingNowProgressInput {
  format: 'epub' | 'pdf' | 'mobi' | 'azw3' | 'djvu'
  currentPage: number | null
  lastProgressPercent: number | null
}

export function formatReadingNowProgress(
  _input: ReadingNowProgressInput,
): string | null {
  // Stub: return null so jest exercises the real value/null comparisons
  // rather than a module-resolution error.
  return null
}
