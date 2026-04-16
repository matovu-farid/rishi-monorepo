// apps/main/src/components/reader/renderers/reflowable/columnPagination.test.ts
import { describe, it, expect } from 'vitest';
import { pageIndexFromScroll, scrollPositionForPage } from './columnPagination';

describe('column pagination', () => {
  it('computes page index from scroll position', () => {
    expect(pageIndexFromScroll(0, 600, 40)).toBe(0);
    expect(pageIndexFromScroll(640, 600, 40)).toBe(1);
    expect(pageIndexFromScroll(1280, 600, 40)).toBe(2);
  });

  it('computes scroll position for a page index', () => {
    expect(scrollPositionForPage(0, 600, 40)).toBe(0);
    expect(scrollPositionForPage(1, 600, 40)).toBe(640);
    expect(scrollPositionForPage(2, 600, 40)).toBe(1280);
  });

  it('round-trips', () => {
    for (let i = 0; i < 10; i++) {
      expect(pageIndexFromScroll(scrollPositionForPage(i, 700, 50), 700, 50)).toBe(i);
    }
  });
});
