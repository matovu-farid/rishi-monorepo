// apps/main/src/components/reader/adapters/useDjvuAdapter.browser.test.ts
// NOTE: Deviations from plan spec:
// 1. File is .browser.test.ts (not .test.ts) — @testing-library/react is not
//    installed; vitest-browser-react is the project's React testing library.
// 2. Uses vitest-browser-react (not @testing-library/react).
// 3. Uses expect.poll() instead of waitFor() — matches the existing browser test
//    pattern in this repo (useMobiAdapter.browser.test.ts).
// 4. renderHook is async (must be awaited) — vitest-browser-react convention.
import { describe, it, expect, vi } from 'vitest';
import { renderHook } from 'vitest-browser-react';
import { useDjvuAdapter } from './useDjvuAdapter';

vi.mock('@/generated', () => ({
  getDjvuPageCount: vi.fn().mockResolvedValue(5),
  getDjvuPage: vi.fn().mockImplementation(async () =>
    new Blob([new Uint8Array([0])], { type: 'image/png' })),
  getDjvuPageText: vi.fn().mockResolvedValue([]),
}));

describe('useDjvuAdapter', () => {
  it('returns paged content with correct page count', async () => {
    const { result } = await renderHook(() => useDjvuAdapter('/path/to/book.djvu'));
    await expect.poll(() => result.current?.status, { timeout: 5000 }).toBe('ready');
    expect(result.current.content?.kind).toBe('paged');
    if (result.current.content?.kind === 'paged') {
      expect(result.current.content.pageCount).toBe(5);
    }
  });

  it('renderPage returns blob source', async () => {
    const { result } = await renderHook(() => useDjvuAdapter('/path/to/book.djvu'));
    await expect.poll(() => result.current?.status, { timeout: 5000 }).toBe('ready');
    if (result.current.content?.kind === 'paged') {
      const page = await result.current.content.renderPage(0, { scale: 1 });
      expect(page.source.kind).toBe('blob');
      if (page.source.kind === 'blob') {
        expect(page.source.url).toMatch(/^blob:/);
      }
    }
  });
});
