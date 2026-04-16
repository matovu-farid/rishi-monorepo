// apps/main/src/components/reader/adapters/useEpubAdapter.browser.test.ts
// NOTE: Deviations from plan spec:
// 1. File is .browser.test.ts (not .test.ts) — project convention for React hook
//    tests requiring a browser environment. The plan's `--browser` flag matches.
// 2. Uses vitest-browser-react (not @testing-library/react) — @testing-library/react
//    is not installed; vitest-browser-react is the project's React testing library.
// 3. Uses expect.poll() instead of waitFor() — matches the existing browser test
//    pattern in this repo (epubwrapper.browser.test.tsx).
// 4. Uses import.meta.url instead of __dirname — __dirname is not available in
//    browser/ESM mode.
import { describe, it, expect } from 'vitest';
import { renderHook } from 'vitest-browser-react';
import { useEpubAdapter } from './useEpubAdapter';

// Resolve fixture path using import.meta.url (ESM-safe, __dirname unavailable in browser mode)
const FIXTURE_URL = new URL('../../../__fixtures__/books/alice.epub', import.meta.url).href;

describe('useEpubAdapter', () => {
  it('loads metadata and chapter spine', async () => {
    // NOTE: vitest-browser-react's renderHook is async — must be awaited
    const { result } = await renderHook(() => useEpubAdapter(FIXTURE_URL));
    await expect.poll(() => result.current?.status, { timeout: 5000 }).toBe('ready');
    expect(result.current.content?.kind).toBe('reflowable');
    // NOTE: alice.epub fixture has no dc:title/dc:creator in its OPF metadata —
    // it's a machine-generated scan. We assert the field exists (may be empty string).
    expect(result.current.content?.metadata).toBeDefined();
    // NOTE: alice.epub has an empty <navMap/> NCX — no TOC items. We assert the
    // array exists; it will be empty for this fixture.
    expect(Array.isArray(result.current.content?.metadata.tableOfContents)).toBe(true);
    if (result.current.content?.kind === 'reflowable') {
      expect(result.current.content.chapters.length).toBeGreaterThan(0);
      const html = await result.current.content.chapters[0].loadHtml();
      expect(typeof html).toBe('string');
      expect(html).toContain('<');
    }
  });

  it('reports error status for invalid path', async () => {
    // NOTE: vitest-browser-react's renderHook is async — must be awaited
    // Using a clearly invalid URL; epubjs will fail to fetch/parse it.
    const { result } = await renderHook(() => useEpubAdapter('http://localhost:1/nonexistent.epub'));
    await expect.poll(() => result.current?.status, { timeout: 10000 }).toBe('error');
    expect(result.current.error).toBeDefined();
  });
});
