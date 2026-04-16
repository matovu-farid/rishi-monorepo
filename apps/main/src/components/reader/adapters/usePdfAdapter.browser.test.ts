// apps/main/src/components/reader/adapters/usePdfAdapter.browser.test.ts
// NOTE: Deviations from plan spec:
// 1. File is .browser.test.ts (not .test.ts) — project convention for React hook
//    tests requiring a browser environment.
// 2. Uses vitest-browser-react (not @testing-library/react) — @testing-library/react
//    is not installed; vitest-browser-react is the project's React testing library.
// 3. Uses expect.poll() instead of waitFor() — matches the existing browser test
//    pattern in this repo (useEpubAdapter.browser.test.ts).
// 4. renderHook is async (must be awaited) — vitest-browser-react convention.
// 5. Uses import.meta.url instead of __dirname — __dirname is not available in
//    browser/ESM mode.
// 6. Fixture URL is fetched as ArrayBuffer and passed to pdfjs.getDocument({data})
//    because file:// URLs may not be accessible directly in the browser test runner.
//    This matches the pattern used in useEpubAdapter (which uses epubjs fetch).
//    The adapter itself is tested with the fixture's HTTP-served URL from Vite.
import { describe, it, expect } from 'vitest';
import { renderHook } from 'vitest-browser-react';
import { usePdfAdapter } from './usePdfAdapter';

// Resolve fixture path using import.meta.url (ESM-safe, __dirname unavailable in browser mode)
const FIXTURE_URL = new URL('../../../__fixtures__/books/alice.pdf', import.meta.url).href;

describe('usePdfAdapter', () => {
  it('loads metadata and page count', async () => {
    const { result } = await renderHook(() => usePdfAdapter(FIXTURE_URL));
    await expect.poll(() => result.current?.status, { timeout: 10000 }).toBe('ready');
    expect(result.current.content?.kind).toBe('paged');
    if (result.current.content?.kind === 'paged') {
      expect(result.current.content.pageCount).toBeGreaterThan(0);
    }
  });

  it('renderPage returns a canvas with text items', async () => {
    const { result } = await renderHook(() => usePdfAdapter(FIXTURE_URL));
    await expect.poll(() => result.current?.status, { timeout: 10000 }).toBe('ready');
    if (result.current.content?.kind === 'paged') {
      const page = await result.current.content.renderPage(0, { scale: 1 });
      expect(page.source.kind).toBe('canvas');
      expect(page.width).toBeGreaterThan(0);
      expect(page.height).toBeGreaterThan(0);
      expect(Array.isArray(page.textItems)).toBe(true);
    }
  });

  it('TOC is an array (may be empty if fixture has no outline)', async () => {
    const { result } = await renderHook(() => usePdfAdapter(FIXTURE_URL));
    await expect.poll(() => result.current?.status, { timeout: 10000 }).toBe('ready');
    if (result.current.content?.kind === 'paged') {
      expect(Array.isArray(result.current.content.metadata.tableOfContents)).toBe(true);
    }
  });
});
