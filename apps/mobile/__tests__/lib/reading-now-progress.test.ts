/**
 * #41 — Library "Reading Now" pill needs a progress subline.
 *
 * The pill on `app/(tabs)/index.tsx` (the `lastReadBook && (...)` block)
 * previously rendered only title + author. Acceptance criteria call for a
 * format-aware progress subline:
 *   - PDF / DJVU  → "Page X of Y" when total is known, else "Page X"
 *   - EPUB / MOBI → "X%" derived from a stored progress float, or null
 *                   when no progress has been recorded yet (legacy books)
 *   - Fallback    → "X%" from `lastProgressPercent` for any format
 *   - No data at all → null (don't render a stale or misleading subline)
 *
 * This file pins the pure formatter that the screen will call. Mounting
 * the screen lives in `library-screen.test.tsx`.
 */

import { formatReadingNowProgress } from '@/lib/reading-now-progress'

describe('#41 — formatReadingNowProgress', () => {
  describe('PDF', () => {
    it('renders "Page X of Y" when both currentPage and totalPages-derived progress are known', () => {
      expect(
        formatReadingNowProgress({
          format: 'pdf',
          currentPage: 42,
          lastProgressPercent: 42 / 100, // implies total=100
        }),
      ).toBe('Page 42 of 100')
    })

    it('renders "Page X" when currentPage is known but progress is null', () => {
      expect(
        formatReadingNowProgress({
          format: 'pdf',
          currentPage: 17,
          lastProgressPercent: null,
        }),
      ).toBe('Page 17')
    })

    it('returns null when no progress data is known (legacy book, never opened post-migration)', () => {
      expect(
        formatReadingNowProgress({
          format: 'pdf',
          currentPage: null,
          lastProgressPercent: null,
        }),
      ).toBeNull()
    })
  })

  describe('DJVU', () => {
    it('renders "Page X of Y" when both currentPage and progress are known', () => {
      expect(
        formatReadingNowProgress({
          format: 'djvu',
          currentPage: 10,
          lastProgressPercent: 0.1,
        }),
      ).toBe('Page 10 of 100')
    })

    it('renders "Page X" when only currentPage is known', () => {
      expect(
        formatReadingNowProgress({
          format: 'djvu',
          currentPage: 5,
          lastProgressPercent: null,
        }),
      ).toBe('Page 5')
    })
  })

  describe('EPUB', () => {
    it('renders "X%" derived from lastProgressPercent', () => {
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: 0.42,
        }),
      ).toBe('42%')
    })

    it('rounds to the nearest whole percent', () => {
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: 0.4249,
        }),
      ).toBe('42%')
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: 0.425,
        }),
      ).toBe('43%')
    })

    it('returns null when no progress is recorded yet', () => {
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: null,
        }),
      ).toBeNull()
    })
  })

  describe('MOBI', () => {
    it('renders "X%" from lastProgressPercent', () => {
      expect(
        formatReadingNowProgress({
          format: 'mobi',
          currentPage: null,
          lastProgressPercent: 0.73,
        }),
      ).toBe('73%')
    })

    it('returns null when no progress data is available', () => {
      expect(
        formatReadingNowProgress({
          format: 'mobi',
          currentPage: null,
          lastProgressPercent: null,
        }),
      ).toBeNull()
    })
  })

  describe('AZW3', () => {
    it('formats like MOBI ("X%" from lastProgressPercent)', () => {
      expect(
        formatReadingNowProgress({
          format: 'azw3',
          currentPage: null,
          lastProgressPercent: 0.5,
        }),
      ).toBe('50%')
    })
  })

  describe('boundary conditions', () => {
    it('clamps lastProgressPercent into [0, 1]', () => {
      // epubjs occasionally emits 1.0000001 at the end of the spine.
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: 1.0001,
        }),
      ).toBe('100%')
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: -0.01,
        }),
      ).toBe('0%')
    })

    it('ignores NaN lastProgressPercent (epubjs pre-locations-ready)', () => {
      expect(
        formatReadingNowProgress({
          format: 'epub',
          currentPage: null,
          lastProgressPercent: Number.NaN,
        }),
      ).toBeNull()
    })
  })
})
