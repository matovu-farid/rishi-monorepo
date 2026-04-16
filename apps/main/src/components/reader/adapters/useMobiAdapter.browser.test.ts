// apps/main/src/components/reader/adapters/useMobiAdapter.browser.test.ts
// NOTE: Deviations from plan spec:
// 1. File is .browser.test.ts (not .test.ts) — @testing-library/react is not
//    installed; vitest-browser-react is the project's React testing library.
// 2. Uses vitest-browser-react (not @testing-library/react).
// 3. Uses expect.poll() instead of waitFor() — matches the existing browser test
//    pattern in this repo (useEpubAdapter.browser.test.ts).
// 4. renderHook is async (must be awaited) — vitest-browser-react convention.
import { describe, it, expect, vi } from 'vitest';
import { renderHook } from 'vitest-browser-react';
import { useMobiAdapter } from './useMobiAdapter';

vi.mock('@/generated', () => ({
  getMobiChapterCount: vi.fn().mockResolvedValue(3),
  getMobiChapter: vi.fn().mockImplementation(async ({ chapterIndex }: { chapterIndex: number }) =>
    `<p>Chapter ${chapterIndex + 1} content</p>`),
}));

describe('useMobiAdapter', () => {
  it('builds chapters from chapter count', async () => {
    const { result } = await renderHook(() => useMobiAdapter('/path/to/book.mobi'));
    await expect.poll(() => result.current?.status, { timeout: 5000 }).toBe('ready');
    expect(result.current.content?.kind).toBe('reflowable');
    if (result.current.content?.kind === 'reflowable') {
      expect(result.current.content.chapters).toHaveLength(3);
      expect(result.current.content.metadata.tableOfContents).toHaveLength(3);
      const html = await result.current.content.chapters[1].loadHtml();
      expect(html).toContain('Chapter 2');
    }
  });

  it('resolveResource returns null (v1 punt)', async () => {
    const { result } = await renderHook(() => useMobiAdapter('/path/to/book.mobi'));
    await expect.poll(() => result.current?.status, { timeout: 5000 }).toBe('ready');
    if (result.current.content?.kind === 'reflowable') {
      expect(await result.current.content.resolveResource('img.png')).toBeNull();
    }
  });
});
