# Unified Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four format-specific view components (EPUB, MOBI, PDF, DJVU) with a unified `ReaderShell` + two renderers (reflowable, paged) + four read-only adapters, dropping `react-reader` and `react-pdf` in favor of direct `epubjs` and `pdfjs-dist` usage.

**Architecture:** Single shell owns all chrome (top bar, panels, TTS controls, gestures, theme). Two renderers handle the two fundamental content shapes: reflowable HTML (EPUB/MOBI) via Shadow DOM + CSS multi-column pagination; paged canvas/image (PDF/DJVU) via virtualized list with text-layer overlay. Four adapters normalize each format into one of the two content shapes. All HTML book content sanitized with DOMPurify before mount.

**Tech Stack:** React 19, TypeScript, Tauri 2, Jotai, TanStack Router, Vitest (browser mode), `epubjs` (parser only), `pdfjs-dist`, `dompurify` (new dep), Shadow DOM.

**Reference docs:**
- Design spec: `docs/superpowers/specs/2026-04-16-unified-reader-design.md`
- QA matrix (pre-merge gate): `docs/superpowers/specs/2026-04-16-unified-reader-qa-matrix.md`

---

## Pre-flight: Test fixtures

The QA matrix and several adapter tests require real fixture books. **The human prepares these once before starting Task 1**:

```
apps/main/src/__fixtures__/books/
  alice.epub         # any small EPUB with TOC + images + a couple of pre-existing highlights
  alice.mobi         # any small MOBI with multiple chapters
  alice.pdf          # any 10-50 page PDF with selectable text + outline
  alice.djvu         # small DJVU with OCR'd text
  malicious.epub     # synthetic EPUB containing <script>, onerror, javascript: href, SVG XSS
                     # see: https://owasp.org/www-community/xss-filter-evasion-cheatsheet
```

If real fixtures are unavailable for a given format, mark the corresponding adapter tests as `it.skip` with a TODO. The plan's logic does not gate on fixture presence except where explicitly noted.

---

## Phase 1: Types and utilities

### Task 1: Reader content model types

**Files:**
- Create: `apps/main/src/types/reader.ts`
- Test: `apps/main/src/types/reader.test-d.ts`

- [ ] **Step 1: Write the type-level test**

```typescript
// apps/main/src/types/reader.test-d.ts
import { expectTypeOf } from 'vitest';
import type {
  BookContent, ReflowableContent, PagedContent, Chapter,
  Location, Paragraph, SelectionInfo, SerializedSelection, AdapterState,
} from './reader';

declare const c: BookContent;
if (c.kind === 'reflowable') expectTypeOf(c).toMatchTypeOf<ReflowableContent>();
if (c.kind === 'paged')      expectTypeOf(c).toMatchTypeOf<PagedContent>();

declare const l: Location;
if (l.kind === 'reflowable') expectTypeOf(l).toHaveProperty('chapterId');
if (l.kind === 'paged')      expectTypeOf(l).toHaveProperty('pageIndex');

declare const s: SerializedSelection;
expectTypeOf(JSON.stringify(s)).toEqualTypeOf<string>();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/types/reader.test-d.ts`
Expected: FAIL — module `./reader` not found.

- [ ] **Step 3: Implement the types**

```typescript
// apps/main/src/types/reader.ts

export type BookContent = ReflowableContent | PagedContent;

export interface ReflowableContent {
  kind: 'reflowable';
  metadata: Metadata;
  chapters: Chapter[];
  resolveResource: (path: string) => Promise<Blob | null>;
}

export interface Chapter {
  id: string;
  index: number;
  title?: string;
  loadHtml: () => Promise<string>;
}

export interface PagedContent {
  kind: 'paged';
  metadata: Metadata;
  pageCount: number;
  renderPage: (pageIndex: number, viewport: Viewport) => Promise<RenderedPage>;
}

export interface Viewport {
  scale: number;
  rotation?: 0 | 90 | 180 | 270;
}

export interface RenderedPage {
  source:
    | { kind: 'canvas'; canvas: HTMLCanvasElement }
    | { kind: 'blob'; url: string };
  textItems: TextItem[];
  width: number;
  height: number;
}

export interface TextItem {
  text: string;
  bbox: { x: number; y: number; width: number; height: number };
}

export interface Metadata {
  title?: string;
  author?: string;
  publisher?: string;
  tableOfContents: TOCEntry[];
}

export interface TOCEntry {
  title: string;
  location: Location;
  children: TOCEntry[];
}

export type Location =
  | { kind: 'reflowable'; chapterId: string; cfi?: string }
  | { kind: 'paged'; pageIndex: number };

export interface Paragraph {
  id: string;
  text: string;
  location: Location;
}

export interface SelectionInfo {
  text: string;
  location: Location;
  rects: DOMRect[];
  serialized: SerializedSelection;
}

export type SerializedSelection =
  | { kind: 'reflowable'; chapterId: string; cfiRange: string }
  | { kind: 'paged'; pageIndex: number; quadPoints: number[] };

export interface AdapterState {
  content: BookContent | null;
  status: 'loading' | 'ready' | 'error';
  error?: Error;
}

export interface RendererHandle {
  next: () => void;
  prev: () => void;
  jumpTo: (loc: Location) => void;
  getCurrentLocation: () => Location;
  applyHighlights: (highlights: AppliedHighlight[]) => void;
}

export interface AppliedHighlight {
  id: string;
  serialized: SerializedSelection;
  color: string;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/types/reader.test-d.ts && bun run lint`
Expected: PASS, no lint errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/types/reader.ts apps/main/src/types/reader.test-d.ts
git commit -m "feat(reader): add unified reader content model types"
```

---

### Task 2: Location codec with legacy fallback

**Files:**
- Create: `apps/main/src/utils/location-codec.ts`
- Test: `apps/main/src/utils/location-codec.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/utils/location-codec.test.ts
import { describe, it, expect } from 'vitest';
import { encodeLocation, decodeLocation } from './location-codec';
import type { Location } from '@/types/reader';

describe('encodeLocation', () => {
  it('round-trips a reflowable location', () => {
    const loc: Location = { kind: 'reflowable', chapterId: 'ch3', cfi: 'epubcfi(/6/4!/4/2)' };
    expect(decodeLocation(encodeLocation(loc), 'epub')).toEqual(loc);
  });

  it('round-trips a paged location', () => {
    const loc: Location = { kind: 'paged', pageIndex: 47 };
    expect(decodeLocation(encodeLocation(loc), 'pdf')).toEqual(loc);
  });
});

describe('decodeLocation legacy fallback', () => {
  it('decodes legacy numeric string for PDF as 0-indexed page', () => {
    expect(decodeLocation('5', 'pdf')).toEqual({ kind: 'paged', pageIndex: 4 });
  });

  it('decodes legacy numeric string for DJVU as 0-indexed page', () => {
    expect(decodeLocation('1', 'djvu')).toEqual({ kind: 'paged', pageIndex: 0 });
  });

  it('decodes legacy numeric string for MOBI as chapter index', () => {
    expect(decodeLocation('3', 'mobi')).toEqual({ kind: 'reflowable', chapterId: '3' });
  });

  it('decodes legacy CFI string for EPUB as reflowable with cfi', () => {
    const cfi = 'epubcfi(/6/4!/4/2)';
    expect(decodeLocation(cfi, 'epub')).toEqual({ kind: 'reflowable', chapterId: '', cfi });
  });

  it('returns sensible defaults for empty/invalid', () => {
    expect(decodeLocation('', 'pdf')).toEqual({ kind: 'paged', pageIndex: 0 });
    expect(decodeLocation('', 'epub')).toEqual({ kind: 'reflowable', chapterId: '' });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/utils/location-codec.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the codec**

```typescript
// apps/main/src/utils/location-codec.ts
import type { Location } from '@/types/reader';

export type BookKind = 'epub' | 'mobi' | 'pdf' | 'djvu';

export function encodeLocation(loc: Location): string {
  return JSON.stringify(loc);
}

export function decodeLocation(raw: string, kind: BookKind): Location {
  if (raw && raw.startsWith('{')) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && (parsed.kind === 'reflowable' || parsed.kind === 'paged')) {
        return parsed as Location;
      }
    } catch {
      // fall through to legacy decode
    }
  }

  if (raw && raw.startsWith('epubcfi(')) {
    return { kind: 'reflowable', chapterId: '', cfi: raw };
  }

  const asNumber = Number(raw);
  if (Number.isFinite(asNumber) && asNumber >= 0) {
    if (kind === 'pdf' || kind === 'djvu') {
      const oneIndexed = Math.max(1, Math.floor(asNumber));
      return { kind: 'paged', pageIndex: oneIndexed - 1 };
    }
    if (kind === 'mobi') {
      return { kind: 'reflowable', chapterId: String(Math.floor(asNumber)) };
    }
  }

  return kind === 'pdf' || kind === 'djvu'
    ? { kind: 'paged', pageIndex: 0 }
    : { kind: 'reflowable', chapterId: '' };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/utils/location-codec.test.ts && bun run lint`
Expected: All tests PASS, no lint errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/utils/location-codec.ts apps/main/src/utils/location-codec.test.ts
git commit -m "feat(reader): add location codec with legacy book.location fallback"
```

---

### Task 3: HTML sanitizer

**Files:**
- Create: `apps/main/src/utils/sanitize-html.ts`
- Test: `apps/main/src/utils/sanitize-html.test.ts`
- Modify: `apps/main/package.json` (add `dompurify` and `@types/dompurify`)

- [ ] **Step 1: Add dependencies**

```bash
cd apps/main && bun add dompurify && bun add -d @types/dompurify
```

- [ ] **Step 2: Write failing tests**

```typescript
// apps/main/src/utils/sanitize-html.test.ts
import { describe, it, expect } from 'vitest';
import { sanitizeBookHtml } from './sanitize-html';

describe('sanitizeBookHtml', () => {
  it('strips <script> tags', () => {
    const out = sanitizeBookHtml('<p>hi</p><script>alert(1)</script>');
    const html = fragmentToString(out);
    expect(html).not.toContain('script');
    expect(html).toContain('hi');
  });

  it('strips inline event handlers', () => {
    const out = sanitizeBookHtml('<img src="x" onerror="alert(1)">');
    expect(fragmentToString(out)).not.toContain('onerror');
  });

  it('strips javascript: URLs in href', () => {
    const out = sanitizeBookHtml('<a href="javascript:alert(1)">click</a>');
    expect(fragmentToString(out)).not.toContain('javascript:');
  });

  it('strips <iframe>, <object>, <embed>', () => {
    const out = sanitizeBookHtml('<iframe src="x"></iframe><object></object><embed>');
    const html = fragmentToString(out);
    expect(html).not.toContain('iframe');
    expect(html).not.toContain('object');
    expect(html).not.toContain('embed');
  });

  it('strips SVG-based XSS', () => {
    const out = sanitizeBookHtml('<svg><script>alert(1)</script></svg>');
    expect(fragmentToString(out)).not.toContain('script');
  });

  it('preserves benign typography', () => {
    const html = '<p>Hello <em>world</em>.</p><blockquote>quoted</blockquote><ul><li>x</li></ul>';
    const out = fragmentToString(sanitizeBookHtml(html));
    expect(out).toContain('<em>world</em>');
    expect(out).toContain('<blockquote>quoted</blockquote>');
    expect(out).toContain('<li>x</li>');
  });

  it('preserves images with safe src attributes', () => {
    const out = fragmentToString(sanitizeBookHtml('<img src="blob:foo" alt="x">'));
    expect(out).toContain('<img');
    expect(out).toContain('src="blob:foo"');
    expect(out).toContain('alt="x"');
  });

  it('preserves internal anchors', () => {
    const out = fragmentToString(sanitizeBookHtml('<a href="#footnote-1">1</a>'));
    expect(out).toContain('href="#footnote-1"');
  });
});

function fragmentToString(fragment: DocumentFragment): string {
  const div = document.createElement('div');
  div.appendChild(fragment);
  // Read serialized markup from a sanitized fragment for assertions.
  return div.outerHTML;
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/utils/sanitize-html.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 4: Implement the sanitizer**

```typescript
// apps/main/src/utils/sanitize-html.ts
import DOMPurify from 'dompurify';

const FORBID_TAGS = ['script', 'iframe', 'object', 'embed', 'frame', 'frameset', 'meta', 'link'];

const FORBID_ATTR = [
  'onload', 'onerror', 'onclick', 'onmouseover', 'onmouseout', 'onmousedown', 'onmouseup',
  'onkeydown', 'onkeyup', 'onkeypress', 'onfocus', 'onblur', 'onchange', 'onsubmit',
  'onreset', 'onselect', 'onabort', 'onresize', 'onscroll', 'onunload', 'oninput',
  'onbeforeunload', 'oncopy', 'oncut', 'onpaste', 'ondrag', 'ondrop', 'ontoggle',
  'onanimationstart', 'onanimationend', 'onanimationiteration',
];

export function sanitizeBookHtml(rawHtml: string): DocumentFragment {
  return DOMPurify.sanitize(rawHtml, {
    RETURN_DOM_FRAGMENT: true,
    FORBID_TAGS,
    FORBID_ATTR,
    ALLOW_DATA_ATTR: false,
    ALLOWED_URI_REGEXP: /^(?:(?:blob|data|https?|mailto|tel|#):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
  });
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/utils/sanitize-html.test.ts --browser`
Expected: All tests PASS.

(Note: this test uses DOM APIs; if `vitest run` fails on `document`, run with `--browser` or move to the browser test config in `vitest.browser.config.ts`.)

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/utils/sanitize-html.ts apps/main/src/utils/sanitize-html.test.ts apps/main/package.json apps/main/bun.lockb
git commit -m "feat(reader): add DOMPurify-based book HTML sanitizer"
```

---

## Phase 2: Adapters

### Task 4: PDF.js worker initialization module

**Files:**
- Create: `apps/main/src/components/reader/adapters/pdfWorker.ts`

- [ ] **Step 1: Implement the worker init**

```typescript
// apps/main/src/components/reader/adapters/pdfWorker.ts
import { pdfjs } from 'pdfjs-dist';

let configured = false;

export function ensurePdfWorker(): void {
  if (configured) return;
  pdfjs.GlobalWorkerOptions.workerSrc = new URL(
    'pdfjs-dist/build/pdf.worker.min.mjs',
    import.meta.url,
  ).toString();
  configured = true;
}
```

- [ ] **Step 2: Verify it imports cleanly**

Run: `cd apps/main && bunx tsc --noEmit`
Expected: No errors. (If `pdfjs` import path differs, mirror the existing `apps/main/src/components/pdf/components/pdf.tsx:5,51-54` import shape.)

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/reader/adapters/pdfWorker.ts
git commit -m "feat(reader): add idempotent PDF.js worker init module"
```

---

### Task 5: useEpubAdapter

**Files:**
- Create: `apps/main/src/components/reader/adapters/useEpubAdapter.ts`
- Test: `apps/main/src/components/reader/adapters/useEpubAdapter.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/adapters/useEpubAdapter.test.ts
import { describe, it, expect } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';
import { useEpubAdapter } from './useEpubAdapter';
import { resolve } from 'path';

const FIXTURE = resolve(__dirname, '../../../__fixtures__/books/alice.epub');

describe('useEpubAdapter', () => {
  it('loads metadata and chapter spine', async () => {
    const { result } = renderHook(() => useEpubAdapter(`file://${FIXTURE}`));
    await waitFor(() => expect(result.current.status).toBe('ready'), { timeout: 5000 });
    expect(result.current.content?.kind).toBe('reflowable');
    expect(result.current.content?.metadata.title).toBeTruthy();
    expect(result.current.content?.metadata.tableOfContents.length).toBeGreaterThan(0);
    if (result.current.content?.kind === 'reflowable') {
      expect(result.current.content.chapters.length).toBeGreaterThan(0);
      const html = await result.current.content.chapters[0].loadHtml();
      expect(typeof html).toBe('string');
      expect(html).toContain('<');
    }
  });

  it('reports error status for invalid path', async () => {
    const { result } = renderHook(() => useEpubAdapter('file:///nonexistent.epub'));
    await waitFor(() => expect(result.current.status).toBe('error'), { timeout: 5000 });
    expect(result.current.error).toBeDefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useEpubAdapter.test.ts --browser`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the adapter**

```typescript
// apps/main/src/components/reader/adapters/useEpubAdapter.ts
import { useEffect, useMemo, useState } from 'react';
import ePub, { Book } from 'epubjs';
import type { AdapterState, ReflowableContent, TOCEntry, Chapter } from '@/types/reader';

export function useEpubAdapter(filepath: string): AdapterState {
  const book = useMemo(() => ePub(filepath), [filepath]);
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await book.ready;
        if (cancelled) return;
        const content = buildContent(book);
        setState({ content, status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => {
      cancelled = true;
      try { book.destroy(); } catch { /* already destroyed */ }
    };
  }, [book]);

  return state;
}

function buildContent(book: Book): ReflowableContent {
  const meta = book.packaging.metadata as Record<string, string | undefined>;
  const chapters: Chapter[] = book.spine.spineItems.map((item, index) => ({
    id: item.idref,
    index,
    title: book.navigation?.get(item.href)?.label?.trim() || undefined,
    loadHtml: async () => {
      const section = book.spine.get(item.idref);
      if (!section) throw new Error(`Spine item ${item.idref} not found`);
      const result = await section.load(book.load.bind(book));
      if (typeof result === 'string') return result;
      return new XMLSerializer().serializeToString(result as Node);
    },
  }));

  return {
    kind: 'reflowable',
    metadata: {
      title: meta.title,
      author: meta.creator,
      publisher: meta.publisher,
      tableOfContents: book.navigation
        ? convertToc(book.navigation.toc, chapters)
        : [],
    },
    chapters,
    resolveResource: async (path) => {
      try {
        const blob = await book.archive.getBlob(path);
        return blob ?? null;
      } catch {
        return null;
      }
    },
  };
}

function convertToc(
  items: Array<{ label: string; href: string; subitems?: Array<{ label: string; href: string; subitems?: unknown }> }>,
  chapters: Chapter[],
): TOCEntry[] {
  return items.map((item) => {
    const chapterId = chapters.find((c) => item.href.includes(c.id))?.id ?? '';
    return {
      title: item.label.trim(),
      location: { kind: 'reflowable', chapterId },
      children: item.subitems ? convertToc(item.subitems as never, chapters) : [],
    };
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useEpubAdapter.test.ts --browser`
Expected: PASS (skip with `it.skip` if no fixture; verify after fixtures added).

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/adapters/useEpubAdapter.ts apps/main/src/components/reader/adapters/useEpubAdapter.test.ts
git commit -m "feat(reader): add useEpubAdapter (epubjs as parser only, no Rendition)"
```

---

### Task 6: useMobiAdapter

**Files:**
- Create: `apps/main/src/components/reader/adapters/useMobiAdapter.ts`
- Test: `apps/main/src/components/reader/adapters/useMobiAdapter.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/adapters/useMobiAdapter.test.ts
import { describe, it, expect, vi } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';
import { useMobiAdapter } from './useMobiAdapter';

vi.mock('@/generated', () => ({
  getMobiChapterCount: vi.fn().mockResolvedValue(3),
  getMobiChapter: vi.fn().mockImplementation(async ({ chapterIndex }) =>
    `<p>Chapter ${chapterIndex + 1} content</p>`),
}));

describe('useMobiAdapter', () => {
  it('builds chapters from chapter count', async () => {
    const { result } = renderHook(() => useMobiAdapter('/path/to/book.mobi'));
    await waitFor(() => expect(result.current.status).toBe('ready'));
    expect(result.current.content?.kind).toBe('reflowable');
    if (result.current.content?.kind === 'reflowable') {
      expect(result.current.content.chapters).toHaveLength(3);
      expect(result.current.content.metadata.tableOfContents).toHaveLength(3);
      const html = await result.current.content.chapters[1].loadHtml();
      expect(html).toContain('Chapter 2');
    }
  });

  it('resolveResource returns null (v1 punt)', async () => {
    const { result } = renderHook(() => useMobiAdapter('/path/to/book.mobi'));
    await waitFor(() => expect(result.current.status).toBe('ready'));
    if (result.current.content?.kind === 'reflowable') {
      expect(await result.current.content.resolveResource('img.png')).toBeNull();
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useMobiAdapter.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the adapter**

```typescript
// apps/main/src/components/reader/adapters/useMobiAdapter.ts
import { useEffect, useState } from 'react';
import { getMobiChapterCount, getMobiChapter } from '@/generated';
import type { AdapterState, ReflowableContent, Chapter, TOCEntry } from '@/types/reader';

export function useMobiAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const count = await getMobiChapterCount({ path: filepath });
        if (cancelled) return;
        setState({ content: buildContent(filepath, count), status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => { cancelled = true; };
  }, [filepath]);

  return state;
}

function buildContent(filepath: string, count: number): ReflowableContent {
  const chapters: Chapter[] = Array.from({ length: count }, (_, index) => ({
    id: String(index),
    index,
    title: `Chapter ${index + 1}`,
    loadHtml: () => getMobiChapter({ path: filepath, chapterIndex: index }),
  }));

  const tableOfContents: TOCEntry[] = chapters.map((c) => ({
    title: c.title!,
    location: { kind: 'reflowable', chapterId: c.id },
    children: [],
  }));

  return {
    kind: 'reflowable',
    metadata: { tableOfContents },
    chapters,
    resolveResource: async () => null, // MOBI inline images: v1 punt
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useMobiAdapter.test.ts`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/adapters/useMobiAdapter.ts apps/main/src/components/reader/adapters/useMobiAdapter.test.ts
git commit -m "feat(reader): add useMobiAdapter (chapter list as flat TOC)"
```

---

### Task 7: usePdfAdapter

**Files:**
- Create: `apps/main/src/components/reader/adapters/usePdfAdapter.ts`
- Test: `apps/main/src/components/reader/adapters/usePdfAdapter.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/adapters/usePdfAdapter.test.ts
import { describe, it, expect } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';
import { usePdfAdapter } from './usePdfAdapter';
import { resolve } from 'path';

const FIXTURE = resolve(__dirname, '../../../__fixtures__/books/alice.pdf');

describe('usePdfAdapter', () => {
  it('loads metadata and page count', async () => {
    const { result } = renderHook(() => usePdfAdapter(`file://${FIXTURE}`));
    await waitFor(() => expect(result.current.status).toBe('ready'), { timeout: 5000 });
    expect(result.current.content?.kind).toBe('paged');
    if (result.current.content?.kind === 'paged') {
      expect(result.current.content.pageCount).toBeGreaterThan(0);
    }
  });

  it('renderPage returns a canvas with text items', async () => {
    const { result } = renderHook(() => usePdfAdapter(`file://${FIXTURE}`));
    await waitFor(() => expect(result.current.status).toBe('ready'), { timeout: 5000 });
    if (result.current.content?.kind === 'paged') {
      const page = await result.current.content.renderPage(0, { scale: 1 });
      expect(page.source.kind).toBe('canvas');
      expect(page.width).toBeGreaterThan(0);
      expect(page.height).toBeGreaterThan(0);
      expect(Array.isArray(page.textItems)).toBe(true);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/usePdfAdapter.test.ts --browser`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the adapter**

```typescript
// apps/main/src/components/reader/adapters/usePdfAdapter.ts
import { useEffect, useState } from 'react';
import { pdfjs } from 'pdfjs-dist';
import type { PDFDocumentProxy } from 'pdfjs-dist';
import type { AdapterState, PagedContent, TextItem, TOCEntry, Location } from '@/types/reader';
import { ensurePdfWorker } from './pdfWorker';

export function usePdfAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });

  useEffect(() => {
    ensurePdfWorker();
    let doc: PDFDocumentProxy | null = null;
    let cancelled = false;
    (async () => {
      try {
        doc = await pdfjs.getDocument(filepath).promise;
        if (cancelled) { doc.destroy(); return; }
        setState({ content: await buildContent(doc), status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => {
      cancelled = true;
      doc?.destroy();
    };
  }, [filepath]);

  return state;
}

async function buildContent(doc: PDFDocumentProxy): Promise<PagedContent> {
  const [metadata, outline] = await Promise.all([doc.getMetadata(), doc.getOutline()]);
  const info = (metadata.info ?? {}) as { Title?: string; Author?: string; Producer?: string };

  return {
    kind: 'paged',
    metadata: {
      title: info.Title,
      author: info.Author,
      publisher: info.Producer,
      tableOfContents: outline ? await convertOutline(outline, doc) : [],
    },
    pageCount: doc.numPages,
    renderPage: async (pageIndex, viewport) => {
      const page = await doc.getPage(pageIndex + 1);
      const vp = page.getViewport({ scale: viewport.scale, rotation: viewport.rotation ?? 0 });
      const canvas = document.createElement('canvas');
      canvas.width = vp.width;
      canvas.height = vp.height;
      const ctx = canvas.getContext('2d');
      if (!ctx) throw new Error('Canvas 2D context unavailable');
      await page.render({ canvasContext: ctx, viewport: vp }).promise;
      const textContent = await page.getTextContent();
      const textItems: TextItem[] = textContent.items
        .filter((it): it is { str: string; transform: number[]; width: number; height: number } =>
          'str' in it && 'transform' in it)
        .map((it) => ({
          text: it.str,
          bbox: { x: it.transform[4], y: vp.height - it.transform[5], width: it.width, height: it.height },
        }));
      return {
        source: { kind: 'canvas', canvas },
        textItems,
        width: vp.width,
        height: vp.height,
      };
    },
  };
}

async function convertOutline(
  outline: Array<{ title: string; dest?: unknown; items?: unknown }>,
  doc: PDFDocumentProxy,
): Promise<TOCEntry[]> {
  const out: TOCEntry[] = [];
  for (const item of outline) {
    const pageIndex = await resolveDestPage(item.dest, doc);
    out.push({
      title: item.title,
      location: { kind: 'paged', pageIndex } as Extract<Location, { kind: 'paged' }>,
      children: item.items ? await convertOutline(item.items as never, doc) : [],
    });
  }
  return out;
}

async function resolveDestPage(dest: unknown, doc: PDFDocumentProxy): Promise<number> {
  try {
    const resolved = typeof dest === 'string' ? await doc.getDestination(dest) : (dest as unknown[]);
    if (!resolved || !Array.isArray(resolved) || resolved.length === 0) return 0;
    const ref = resolved[0];
    const pageIndex = await doc.getPageIndex(ref as never);
    return pageIndex;
  } catch {
    return 0;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/usePdfAdapter.test.ts --browser`
Expected: All tests PASS (skip with `it.skip` if no fixture).

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/adapters/usePdfAdapter.ts apps/main/src/components/reader/adapters/usePdfAdapter.test.ts
git commit -m "feat(reader): add usePdfAdapter (direct pdfjs-dist; outline → TOC)"
```

---

### Task 8: useDjvuAdapter

**Files:**
- Create: `apps/main/src/components/reader/adapters/useDjvuAdapter.ts`
- Test: `apps/main/src/components/reader/adapters/useDjvuAdapter.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/adapters/useDjvuAdapter.test.ts
import { describe, it, expect, vi } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';
import { useDjvuAdapter } from './useDjvuAdapter';

vi.mock('@/generated', () => ({
  getDjvuPageCount: vi.fn().mockResolvedValue(5),
  getDjvuPage: vi.fn().mockImplementation(async () =>
    new Blob([new Uint8Array([0])], { type: 'image/png' })),
  getDjvuPageText: vi.fn().mockResolvedValue([]),
}));

describe('useDjvuAdapter', () => {
  it('returns paged content with correct page count', async () => {
    const { result } = renderHook(() => useDjvuAdapter('/path/to/book.djvu'));
    await waitFor(() => expect(result.current.status).toBe('ready'));
    expect(result.current.content?.kind).toBe('paged');
    if (result.current.content?.kind === 'paged') {
      expect(result.current.content.pageCount).toBe(5);
    }
  });

  it('renderPage returns blob source', async () => {
    const { result } = renderHook(() => useDjvuAdapter('/path/to/book.djvu'));
    await waitFor(() => expect(result.current.status).toBe('ready'));
    if (result.current.content?.kind === 'paged') {
      const page = await result.current.content.renderPage(0, { scale: 1 });
      expect(page.source.kind).toBe('blob');
      if (page.source.kind === 'blob') {
        expect(page.source.url).toMatch(/^blob:/);
      }
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useDjvuAdapter.test.ts --browser`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the adapter**

```typescript
// apps/main/src/components/reader/adapters/useDjvuAdapter.ts
import { useEffect, useRef, useState } from 'react';
import { getDjvuPageCount, getDjvuPage, getDjvuPageText } from '@/generated';
import type { AdapterState, PagedContent, RenderedPage, TextItem } from '@/types/reader';

const CACHE_SIZE = 5;
const DEFAULT_DPI = 150;

class LruCache {
  private order: number[] = [];
  private store = new Map<number, RenderedPage>();
  constructor(private maxSize: number) {}

  get(key: number): RenderedPage | undefined {
    const value = this.store.get(key);
    if (value) {
      this.order = this.order.filter((k) => k !== key);
      this.order.push(key);
    }
    return value;
  }

  set(key: number, value: RenderedPage): void {
    this.store.set(key, value);
    this.order.push(key);
    while (this.order.length > this.maxSize) {
      const evict = this.order.shift()!;
      const evicted = this.store.get(evict);
      if (evicted?.source.kind === 'blob') URL.revokeObjectURL(evicted.source.url);
      this.store.delete(evict);
    }
  }

  clear(): void {
    for (const page of this.store.values()) {
      if (page.source.kind === 'blob') URL.revokeObjectURL(page.source.url);
    }
    this.store.clear();
    this.order = [];
  }
}

export function useDjvuAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });
  const cacheRef = useRef(new LruCache(CACHE_SIZE));

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const pageCount = await getDjvuPageCount({ path: filepath });
        if (cancelled) return;
        setState({ content: buildContent(filepath, pageCount, cacheRef.current), status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => {
      cancelled = true;
      cacheRef.current.clear();
    };
  }, [filepath]);

  return state;
}

function buildContent(filepath: string, pageCount: number, cache: LruCache): PagedContent {
  return {
    kind: 'paged',
    metadata: { tableOfContents: [] }, // DJVU TOC: v1 punt
    pageCount,
    renderPage: async (pageIndex, viewport) => {
      const cached = cache.get(pageIndex);
      if (cached) return cached;
      const dpi = Math.round(DEFAULT_DPI * viewport.scale);
      const blob = await getDjvuPage({ path: filepath, pageIndex, dpi });
      const url = URL.createObjectURL(blob);
      const rawText = await getDjvuPageText({ path: filepath, pageIndex }).catch(() => []);
      const bitmap = await createImageBitmap(blob);
      const page: RenderedPage = {
        source: { kind: 'blob', url },
        textItems: (rawText as Array<{ text: string; x: number; y: number; w: number; h: number }>)
          .map((it): TextItem => ({ text: it.text, bbox: { x: it.x, y: it.y, width: it.w, height: it.h } })),
        width: bitmap.width,
        height: bitmap.height,
      };
      bitmap.close();
      cache.set(pageIndex, page);
      return page;
    },
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useDjvuAdapter.test.ts --browser`
Expected: All tests PASS.

(Note: `getDjvuPage`/`getDjvuPageText` signatures should match `@/generated`. If their actual return types differ, adjust the cast in the test mock and the body. Verify by reading `apps/main/src/generated/index.ts` before implementing.)

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/adapters/useDjvuAdapter.ts apps/main/src/components/reader/adapters/useDjvuAdapter.test.ts
git commit -m "feat(reader): add useDjvuAdapter with LRU page cache"
```

---

### Task 9: useBookAdapter dispatcher

**Files:**
- Create: `apps/main/src/components/reader/adapters/useBookAdapter.ts`
- Test: `apps/main/src/components/reader/adapters/useBookAdapter.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/adapters/useBookAdapter.test.ts
import { describe, it, expect, vi } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useBookAdapter } from './useBookAdapter';

vi.mock('./useEpubAdapter', () => ({ useEpubAdapter: vi.fn(() => ({ content: { kind: 'reflowable' }, status: 'ready' })) }));
vi.mock('./useMobiAdapter', () => ({ useMobiAdapter: vi.fn(() => ({ content: { kind: 'reflowable' }, status: 'ready' })) }));
vi.mock('./usePdfAdapter',  () => ({ usePdfAdapter:  vi.fn(() => ({ content: { kind: 'paged' },      status: 'ready' })) }));
vi.mock('./useDjvuAdapter', () => ({ useDjvuAdapter: vi.fn(() => ({ content: { kind: 'paged' },      status: 'ready' })) }));

describe('useBookAdapter', () => {
  it.each([
    ['epub', 'reflowable'],
    ['mobi', 'reflowable'],
    ['pdf',  'paged'],
    ['djvu', 'paged'],
  ] as const)('dispatches %s to %s adapter', (kind, expectedKind) => {
    const book = { id: 1, kind, filepath: '/x' } as never;
    const { result } = renderHook(() => useBookAdapter(book));
    expect(result.current.content?.kind).toBe(expectedKind);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useBookAdapter.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the dispatcher**

```typescript
// apps/main/src/components/reader/adapters/useBookAdapter.ts
import type { Book } from '@/generated';
import type { AdapterState } from '@/types/reader';
import { useEpubAdapter } from './useEpubAdapter';
import { useMobiAdapter } from './useMobiAdapter';
import { usePdfAdapter } from './usePdfAdapter';
import { useDjvuAdapter } from './useDjvuAdapter';

export function useBookAdapter(book: Book): AdapterState {
  // Hooks-in-conditional is safe here: book.kind is stable for a route mount.
  // The route component remounts (via key={book.id}) when switching books.
  switch (book.kind) {
    case 'epub': return useEpubAdapter(book.filepath);
    case 'mobi': return useMobiAdapter(book.filepath);
    case 'pdf':  return usePdfAdapter(book.filepath);
    case 'djvu': return useDjvuAdapter(book.filepath);
    default:
      throw new Error(`Unknown book kind: ${book.kind}`);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/adapters/useBookAdapter.test.ts && bun run lint`
Expected: All PASS, no lint errors. **Add `// eslint-disable-next-line react-hooks/rules-of-hooks`** above the switch lines if the linter objects.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/adapters/useBookAdapter.ts apps/main/src/components/reader/adapters/useBookAdapter.test.ts
git commit -m "feat(reader): add useBookAdapter dispatcher"
```

---

## Phase 3: Renderers

### Task 10: Renderer types

**Files:**
- Create: `apps/main/src/components/reader/renderers/types.ts`

- [ ] **Step 1: Implement renderer prop types**

```typescript
// apps/main/src/components/reader/renderers/types.ts
import type {
  ReflowableContent, PagedContent, Location, Paragraph, SelectionInfo,
  Viewport, RendererHandle, AppliedHighlight,
} from '@/types/reader';

export type Theme = {
  bg: string;
  fg: string;
  accent: string;
};

export type FontSettings = {
  family: string;
  size: number; // px
  lineHeight: number; // unitless
};

export interface ReflowableRendererProps {
  content: ReflowableContent;
  location: Extract<Location, { kind: 'reflowable' }>;
  theme: Theme;
  fontSettings: FontSettings;
  highlights: AppliedHighlight[];
  onLocationChange:          (loc: Location) => void;
  onVisibleParagraphsChange: (paragraphs: Paragraph[]) => void;
  onSelection:               (selection: SelectionInfo | null) => void;
}

export interface PagedRendererProps {
  content: PagedContent;
  location: Extract<Location, { kind: 'paged' }>;
  theme: Theme;
  viewport: Viewport;
  invertedDarkMode: boolean;
  highlights: AppliedHighlight[];
  onLocationChange:          (loc: Location) => void;
  onVisibleParagraphsChange: (paragraphs: Paragraph[]) => void;
  onSelection:               (selection: SelectionInfo | null) => void;
}

export type { RendererHandle };
```

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/main && bunx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/reader/renderers/types.ts
git commit -m "feat(reader): add renderer prop and handle types"
```

---

### Task 11: ChapterFrame (shadow root mounting)

**Files:**
- Create: `apps/main/src/components/reader/renderers/reflowable/ChapterFrame.tsx`
- Test: `apps/main/src/components/reader/renderers/reflowable/ChapterFrame.test.tsx`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/renderers/reflowable/ChapterFrame.test.tsx
import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-react';
import { ChapterFrame } from './ChapterFrame';

describe('ChapterFrame', () => {
  it('mounts sanitized HTML inside shadow root', async () => {
    const html = '<p>hello</p><script>window.X=1</script>';
    const { container } = render(
      <ChapterFrame
        html={html}
        themeStyles=":host{color:red}"
        resolveResource={async () => null}
      />,
    );
    const host = container.querySelector('.chapter-frame-host') as HTMLElement;
    expect(host).toBeTruthy();
    const shadow = host.shadowRoot!;
    expect(shadow).toBeTruthy();
    expect(shadow.querySelector('p')?.textContent).toBe('hello');
    expect(shadow.querySelector('script')).toBeNull();
    expect((window as never as { X?: number }).X).toBeUndefined();
  });

  it('rewrites internal img src via resolveResource', async () => {
    const blob = new Blob(['x'], { type: 'image/png' });
    const html = '<p><img src="images/foo.png" alt="f"></p>';
    const { container } = render(
      <ChapterFrame
        html={html}
        themeStyles=""
        resolveResource={async (path) => (path === 'images/foo.png' ? blob : null)}
      />,
    );
    const host = container.querySelector('.chapter-frame-host') as HTMLElement;
    await new Promise((r) => setTimeout(r, 50)); // wait for async resolveResource
    const img = host.shadowRoot!.querySelector('img') as HTMLImageElement;
    expect(img.src).toMatch(/^blob:/);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/renderers/reflowable/ChapterFrame.test.tsx --browser`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement ChapterFrame**

```tsx
// apps/main/src/components/reader/renderers/reflowable/ChapterFrame.tsx
import { useEffect, useRef } from 'react';
import { sanitizeBookHtml } from '@/utils/sanitize-html';

export interface ChapterFrameProps {
  html: string;
  themeStyles: string;
  resolveResource: (path: string) => Promise<Blob | null>;
}

export function ChapterFrame({ html, themeStyles, resolveResource }: ChapterFrameProps) {
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const shadow = host.shadowRoot ?? host.attachShadow({ mode: 'open' });

    const styleEl = document.createElement('style');
    styleEl.textContent = themeStyles;

    const fragment = sanitizeBookHtml(html);

    while (shadow.firstChild) shadow.removeChild(shadow.firstChild);
    shadow.appendChild(styleEl);
    shadow.appendChild(fragment);

    const blobUrls: string[] = [];

    const imgs = Array.from(shadow.querySelectorAll('img')) as HTMLImageElement[];
    for (const img of imgs) {
      const src = img.getAttribute('src');
      if (!src || src.startsWith('blob:') || src.startsWith('data:') || /^https?:/.test(src)) continue;
      void resolveResource(src).then((blob) => {
        if (blob) {
          const url = URL.createObjectURL(blob);
          img.setAttribute('src', url);
          blobUrls.push(url);
        } else {
          img.removeAttribute('src');
        }
      });
    }

    return () => {
      for (const url of blobUrls) URL.revokeObjectURL(url);
    };
  }, [html, themeStyles, resolveResource]);

  return <div className="chapter-frame-host" ref={hostRef} style={{ height: '100%', width: '100%' }} />;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/reflowable/ChapterFrame.test.tsx`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/reflowable/ChapterFrame.tsx apps/main/src/components/reader/renderers/reflowable/ChapterFrame.test.tsx
git commit -m "feat(reader): add ChapterFrame with shadow DOM and resource rewrite"
```

---

### Task 12: Column pagination utility

**Files:**
- Create: `apps/main/src/components/reader/renderers/reflowable/columnPagination.ts`
- Test: `apps/main/src/components/reader/renderers/reflowable/columnPagination.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bunx vitest run src/components/reader/renderers/reflowable/columnPagination.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

```typescript
// apps/main/src/components/reader/renderers/reflowable/columnPagination.ts
export function pageIndexFromScroll(scrollLeft: number, columnWidth: number, gap: number): number {
  return Math.round(scrollLeft / (columnWidth + gap));
}

export function scrollPositionForPage(pageIndex: number, columnWidth: number, gap: number): number {
  return pageIndex * (columnWidth + gap);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bunx vitest run src/components/reader/renderers/reflowable/columnPagination.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/reflowable/columnPagination.ts apps/main/src/components/reader/renderers/reflowable/columnPagination.test.ts
git commit -m "feat(reader): add column pagination math helpers"
```

---

### Task 13: Paragraph extractor for reflowable content

**Files:**
- Create: `apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.ts`
- Test: `apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.test.ts`

- [ ] **Step 1: Write failing tests**

```typescript
// apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.test.ts
import { describe, it, expect } from 'vitest';
import { extractVisibleParagraphs } from './paragraphExtractor';
import { sanitizeBookHtml } from '@/utils/sanitize-html';

function setup(html: string): ShadowRoot {
  const host = document.createElement('div');
  host.style.width = '600px';
  host.style.height = '400px';
  document.body.appendChild(host);
  const root = host.attachShadow({ mode: 'open' });
  // Use sanitizeBookHtml to construct a DOM fragment from a known-safe test string,
  // then append it to the shadow root. Avoids innerHTML.
  root.appendChild(sanitizeBookHtml(html));
  return root;
}

describe('extractVisibleParagraphs', () => {
  it('extracts block-level text elements', () => {
    const root = setup('<p>one</p><p>two</p><h2>three</h2>');
    const result = extractVisibleParagraphs(root, 'chapter-id');
    expect(result.length).toBe(3);
    expect(result.map((p) => p.text)).toEqual(['one', 'two', 'three']);
    expect(result[0].location.kind).toBe('reflowable');
  });

  it('ignores empty elements', () => {
    const root = setup('<p>one</p><p>   </p><p>two</p>');
    const result = extractVisibleParagraphs(root, 'c');
    expect(result.map((p) => p.text)).toEqual(['one', 'two']);
  });

  it('produces stable ids based on chapter and DOM position', () => {
    const root = setup('<p>x</p><p>y</p>');
    const a = extractVisibleParagraphs(root, 'c1');
    const b = extractVisibleParagraphs(root, 'c1');
    expect(a.map((p) => p.id)).toEqual(b.map((p) => p.id));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/reflowable/paragraphExtractor.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement extractor**

```typescript
// apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.ts
import type { Paragraph } from '@/types/reader';

const BLOCK_SELECTOR = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, dt, dd, figcaption';

export function extractVisibleParagraphs(root: ShadowRoot | HTMLElement, chapterId: string): Paragraph[] {
  const elements = Array.from(root.querySelectorAll(BLOCK_SELECTOR));
  const paragraphs: Paragraph[] = [];
  for (let i = 0; i < elements.length; i++) {
    const el = elements[i];
    const text = (el.textContent ?? '').trim();
    if (!text) continue;
    paragraphs.push({
      id: `${chapterId}::${i}`,
      text,
      location: { kind: 'reflowable', chapterId, cfi: `${chapterId}::${i}` },
    });
  }
  return paragraphs;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/reflowable/paragraphExtractor.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.ts apps/main/src/components/reader/renderers/reflowable/paragraphExtractor.test.ts
git commit -m "feat(reader): add reflowable paragraph extractor with stable ids"
```

---

### Task 14: ReflowableRenderer assembled

**Files:**
- Create: `apps/main/src/components/reader/renderers/ReflowableRenderer.tsx`
- Test: `apps/main/src/components/reader/renderers/ReflowableRenderer.test.tsx`

- [ ] **Step 1: Write failing test**

```typescript
// apps/main/src/components/reader/renderers/ReflowableRenderer.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { useRef } from 'react';
import { ReflowableRenderer } from './ReflowableRenderer';
import type { ReflowableContent, RendererHandle } from '@/types/reader';

const fakeContent: ReflowableContent = {
  kind: 'reflowable',
  metadata: { tableOfContents: [] },
  chapters: [
    { id: 'c1', index: 0, loadHtml: async () => '<p>chap one</p>' },
    { id: 'c2', index: 1, loadHtml: async () => '<p>chap two</p>' },
  ],
  resolveResource: async () => null,
};

function Harness({ onParagraphs }: { onParagraphs: (p: unknown[]) => void }) {
  const ref = useRef<RendererHandle>(null);
  return (
    <div style={{ width: 600, height: 400 }}>
      <ReflowableRenderer
        ref={ref}
        content={fakeContent}
        location={{ kind: 'reflowable', chapterId: 'c1' }}
        theme={{ bg: '#fff', fg: '#000', accent: '#06f' }}
        fontSettings={{ family: 'serif', size: 16, lineHeight: 1.5 }}
        highlights={[]}
        onLocationChange={() => {}}
        onVisibleParagraphsChange={onParagraphs}
        onSelection={() => {}}
      />
    </div>
  );
}

describe('ReflowableRenderer', () => {
  it('mounts the requested chapter and emits paragraphs', async () => {
    const onParagraphs = vi.fn();
    render(<Harness onParagraphs={onParagraphs} />);
    await new Promise((r) => setTimeout(r, 200));
    const calls = onParagraphs.mock.calls.flat();
    expect(calls.some((c: unknown[]) => Array.isArray(c) && c.length > 0)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/ReflowableRenderer.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement ReflowableRenderer**

```tsx
// apps/main/src/components/reader/renderers/ReflowableRenderer.tsx
import { forwardRef, useEffect, useImperativeHandle, useRef, useState, useMemo } from 'react';
import type { Chapter, Location, RendererHandle, SerializedSelection } from '@/types/reader';
import type { ReflowableRendererProps } from './types';
import { ChapterFrame } from './reflowable/ChapterFrame';
import { extractVisibleParagraphs } from './reflowable/paragraphExtractor';
import { pageIndexFromScroll, scrollPositionForPage } from './reflowable/columnPagination';

const COLUMN_GAP = 40;

export const ReflowableRenderer = forwardRef<RendererHandle, ReflowableRendererProps>(
  function ReflowableRenderer(props, ref) {
    const { content, location, theme, fontSettings, onLocationChange, onVisibleParagraphsChange, onSelection } = props;
    const containerRef = useRef<HTMLDivElement>(null);
    const [chapter, setChapter] = useState<Chapter | null>(null);
    const [html, setHtml] = useState<string>('');
    const [columnWidth, setColumnWidth] = useState<number>(600);

    useEffect(() => {
      const target = content.chapters.find((c) => c.id === location.chapterId) ?? content.chapters[0];
      if (!target) return;
      setChapter(target);
      let cancelled = false;
      void target.loadHtml().then((h) => { if (!cancelled) setHtml(h); });
      return () => { cancelled = true; };
    }, [content, location.chapterId]);

    useEffect(() => {
      if (!containerRef.current) return;
      const el = containerRef.current;
      const observer = new ResizeObserver(() => {
        setColumnWidth(el.clientWidth);
      });
      observer.observe(el);
      return () => observer.disconnect();
    }, []);

    const themeStyles = useMemo(() => `
      :host {
        display: block;
        height: 100%;
        background: ${theme.bg};
        color: ${theme.fg};
        font-family: ${fontSettings.family};
        font-size: ${fontSettings.size}px;
        line-height: ${fontSettings.lineHeight};
      }
      a { color: ${theme.accent}; }
      img { max-width: 100%; height: auto; }
      p { margin: 0.6em 0; }
    `, [theme, fontSettings]);

    useEffect(() => {
      const container = containerRef.current;
      if (!container || !chapter) return;
      const handler = () => {
        const pageIdx = pageIndexFromScroll(container.scrollLeft, columnWidth, COLUMN_GAP);
        const newLoc: Extract<Location, { kind: 'reflowable' }> = {
          kind: 'reflowable',
          chapterId: chapter.id,
          cfi: `${chapter.id}::page::${pageIdx}`,
        };
        onLocationChange(newLoc);
        const host = container.querySelector('.chapter-frame-host') as HTMLElement | null;
        if (host?.shadowRoot) {
          onVisibleParagraphsChange(extractVisibleParagraphs(host.shadowRoot, chapter.id));
        }
      };
      const debounced = debounce(handler, 100);
      container.addEventListener('scroll', debounced, { passive: true });
      handler();
      return () => container.removeEventListener('scroll', debounced);
    }, [chapter, columnWidth, onLocationChange, onVisibleParagraphsChange]);

    useEffect(() => {
      const handler = () => {
        const sel = document.getSelection();
        if (!sel || sel.isCollapsed || !chapter) {
          onSelection(null);
          return;
        }
        const text = sel.toString().trim();
        if (!text) { onSelection(null); return; }
        const range = sel.getRangeAt(0);
        const rects = Array.from(range.getClientRects());
        onSelection({
          text,
          location: { kind: 'reflowable', chapterId: chapter.id },
          rects,
          serialized: { kind: 'reflowable', chapterId: chapter.id, cfiRange: serializeRange(range, chapter.id) },
        });
      };
      document.addEventListener('selectionchange', handler);
      return () => document.removeEventListener('selectionchange', handler);
    }, [chapter, onSelection]);

    useImperativeHandle(ref, () => ({
      next: () => {
        const c = containerRef.current; if (!c || !chapter) return;
        const cur = pageIndexFromScroll(c.scrollLeft, columnWidth, COLUMN_GAP);
        const max = Math.floor((c.scrollWidth - c.clientWidth) / (columnWidth + COLUMN_GAP));
        if (cur < max) {
          c.scrollTo({ left: scrollPositionForPage(cur + 1, columnWidth, COLUMN_GAP), behavior: 'smooth' });
        } else {
          const next = content.chapters[chapter.index + 1];
          if (next) onLocationChange({ kind: 'reflowable', chapterId: next.id });
        }
      },
      prev: () => {
        const c = containerRef.current; if (!c || !chapter) return;
        const cur = pageIndexFromScroll(c.scrollLeft, columnWidth, COLUMN_GAP);
        if (cur > 0) {
          c.scrollTo({ left: scrollPositionForPage(cur - 1, columnWidth, COLUMN_GAP), behavior: 'smooth' });
        } else {
          const prev = content.chapters[chapter.index - 1];
          if (prev) onLocationChange({ kind: 'reflowable', chapterId: prev.id });
        }
      },
      jumpTo: (loc) => {
        if (loc.kind !== 'reflowable') return;
        onLocationChange(loc);
      },
      getCurrentLocation: () => {
        const c = containerRef.current;
        if (!c || !chapter) return { kind: 'reflowable', chapterId: location.chapterId };
        const pageIdx = pageIndexFromScroll(c.scrollLeft, columnWidth, COLUMN_GAP);
        return { kind: 'reflowable', chapterId: chapter.id, cfi: `${chapter.id}::page::${pageIdx}` };
      },
      applyHighlights: (highlights) => {
        const host = containerRef.current?.querySelector('.chapter-frame-host') as HTMLElement | null;
        if (!host?.shadowRoot) return;
        applyMarks(host.shadowRoot, highlights);
      },
    }), [chapter, columnWidth, content, location, onLocationChange]);

    return (
      <div
        ref={containerRef}
        style={{
          height: '100%',
          width: '100%',
          overflowX: 'auto',
          overflowY: 'hidden',
          scrollSnapType: 'x mandatory',
          columnWidth: `${columnWidth}px`,
          columnGap: `${COLUMN_GAP}px`,
          background: theme.bg,
        }}
      >
        {chapter && html && (
          <ChapterFrame html={html} themeStyles={themeStyles} resolveResource={content.resolveResource} />
        )}
      </div>
    );
  },
);

function debounce<T extends (...args: never[]) => void>(fn: T, ms: number): T {
  let t: ReturnType<typeof setTimeout> | null = null;
  return ((...args: never[]) => {
    if (t) clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  }) as T;
}

function serializeRange(range: Range, chapterId: string): string {
  const startPath = pathFromRoot(range.startContainer);
  const endPath = pathFromRoot(range.endContainer);
  return `${chapterId}::${startPath}:${range.startOffset}/${endPath}:${range.endOffset}`;
}

function pathFromRoot(node: Node): string {
  const parts: string[] = [];
  let current: Node | null = node;
  while (current && current.parentNode && !(current.parentNode instanceof ShadowRoot)) {
    const parent = current.parentNode;
    const idx = Array.prototype.indexOf.call(parent.childNodes, current);
    parts.unshift(String(idx));
    current = parent;
  }
  return parts.join('/');
}

function applyMarks(_root: ShadowRoot, _highlights: { id: string; serialized: SerializedSelection; color: string }[]): void {
  // Real implementation lands in Task 26 (highlight loading + apply).
  // Stub kept here so the imperative handle has a defined method signature.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/ReflowableRenderer.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/ReflowableRenderer.tsx apps/main/src/components/reader/renderers/ReflowableRenderer.test.tsx
git commit -m "feat(reader): add ReflowableRenderer (CSS columns, shadow DOM, selection)"
```

(Note: `applyMarks` is a stub; replaced with the full implementation in Task 26 once highlight loading lands. The stub is acceptable in this commit because no live code calls it yet.)

---

### Task 15: PageSlot for paged renderer

**Files:**
- Create: `apps/main/src/components/reader/renderers/paged/PageSlot.tsx`
- Test: `apps/main/src/components/reader/renderers/paged/PageSlot.test.tsx`

- [ ] **Step 1: Write failing test**

```typescript
// apps/main/src/components/reader/renderers/paged/PageSlot.test.tsx
import { describe, it, expect } from 'vitest';
import { render } from 'vitest-browser-react';
import { PageSlot } from './PageSlot';
import type { RenderedPage } from '@/types/reader';

describe('PageSlot', () => {
  it('renders a canvas page', async () => {
    const canvas = document.createElement('canvas');
    canvas.width = 100; canvas.height = 200;
    const page: RenderedPage = {
      source: { kind: 'canvas', canvas },
      textItems: [],
      width: 100, height: 200,
    };
    const { container } = render(<PageSlot page={page} invertedDarkMode={false} />);
    expect(container.querySelector('canvas')).toBeTruthy();
  });

  it('renders a blob page as <img>', async () => {
    const url = URL.createObjectURL(new Blob(['x'], { type: 'image/png' }));
    const page: RenderedPage = {
      source: { kind: 'blob', url },
      textItems: [],
      width: 100, height: 200,
    };
    const { container } = render(<PageSlot page={page} invertedDarkMode={false} />);
    const img = container.querySelector('img') as HTMLImageElement;
    expect(img.src).toBe(url);
    URL.revokeObjectURL(url);
  });

  it('applies inverted filter when invertedDarkMode is true', () => {
    const canvas = document.createElement('canvas');
    const page: RenderedPage = {
      source: { kind: 'canvas', canvas },
      textItems: [],
      width: 10, height: 10,
    };
    const { container } = render(<PageSlot page={page} invertedDarkMode={true} />);
    const layer = container.querySelector('.page-image-layer') as HTMLElement;
    expect(layer.style.filter).toContain('invert');
  });

  it('overlays text items as positioned spans', () => {
    const canvas = document.createElement('canvas');
    const page: RenderedPage = {
      source: { kind: 'canvas', canvas },
      textItems: [{ text: 'hi', bbox: { x: 10, y: 20, width: 30, height: 12 } }],
      width: 100, height: 100,
    };
    const { container } = render(<PageSlot page={page} invertedDarkMode={false} />);
    const span = container.querySelector('.page-text-layer span') as HTMLElement;
    expect(span.textContent).toBe('hi');
    expect(span.style.left).toBe('10px');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/paged/PageSlot.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement PageSlot**

```tsx
// apps/main/src/components/reader/renderers/paged/PageSlot.tsx
import { useEffect, useRef } from 'react';
import type { RenderedPage } from '@/types/reader';

export interface PageSlotProps {
  page: RenderedPage;
  invertedDarkMode: boolean;
}

export function PageSlot({ page, invertedDarkMode }: PageSlotProps) {
  const canvasContainerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (page.source.kind !== 'canvas') return;
    const container = canvasContainerRef.current;
    if (!container) return;
    while (container.firstChild) container.removeChild(container.firstChild);
    container.appendChild(page.source.canvas);
    return () => {
      try { container.removeChild(page.source.canvas as Node); } catch { /* already detached */ }
    };
  }, [page]);

  return (
    <div style={{ position: 'relative', width: page.width, height: page.height, margin: '8px auto' }}>
      <div
        className="page-image-layer"
        style={{
          width: page.width,
          height: page.height,
          filter: invertedDarkMode ? 'invert(1) hue-rotate(180deg)' : 'none',
        }}
      >
        {page.source.kind === 'canvas' ? (
          <div ref={canvasContainerRef} />
        ) : (
          <img src={page.source.url} alt="" width={page.width} height={page.height} draggable={false} />
        )}
      </div>
      <div
        className="page-text-layer"
        style={{
          position: 'absolute', inset: 0,
          color: 'transparent', userSelect: 'text',
          pointerEvents: 'none',
        }}
      >
        {page.textItems.map((item, i) => (
          <span
            key={i}
            style={{
              position: 'absolute',
              left: `${item.bbox.x}px`,
              top: `${item.bbox.y - item.bbox.height}px`,
              width: `${item.bbox.width}px`,
              height: `${item.bbox.height}px`,
              fontSize: `${item.bbox.height}px`,
              lineHeight: 1,
              whiteSpace: 'pre',
              pointerEvents: 'auto',
            }}
          >
            {item.text}
          </span>
        ))}
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/paged/PageSlot.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/paged/PageSlot.tsx apps/main/src/components/reader/renderers/paged/PageSlot.test.tsx
git commit -m "feat(reader): add PageSlot with text-layer overlay"
```

---

### Task 16: PagedRenderer assembled

**Files:**
- Create: `apps/main/src/components/reader/renderers/PagedRenderer.tsx`
- Test: `apps/main/src/components/reader/renderers/PagedRenderer.test.tsx`

- [ ] **Step 1: Write failing test**

```typescript
// apps/main/src/components/reader/renderers/PagedRenderer.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { PagedRenderer } from './PagedRenderer';
import type { PagedContent } from '@/types/reader';

const fakeContent: PagedContent = {
  kind: 'paged',
  metadata: { tableOfContents: [] },
  pageCount: 3,
  renderPage: vi.fn(async () => {
    const canvas = document.createElement('canvas');
    canvas.width = 100; canvas.height = 100;
    return { source: { kind: 'canvas' as const, canvas }, textItems: [], width: 100, height: 100 };
  }),
};

describe('PagedRenderer', () => {
  it('renders the current page', async () => {
    const { container } = render(
      <PagedRenderer
        content={fakeContent}
        location={{ kind: 'paged', pageIndex: 0 }}
        theme={{ bg: '#fff', fg: '#000', accent: '#06f' }}
        viewport={{ scale: 1 }}
        invertedDarkMode={false}
        highlights={[]}
        onLocationChange={() => {}}
        onVisibleParagraphsChange={() => {}}
        onSelection={() => {}}
      />,
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(container.querySelector('canvas')).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/PagedRenderer.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement PagedRenderer**

```tsx
// apps/main/src/components/reader/renderers/PagedRenderer.tsx
import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import type { RenderedPage, RendererHandle } from '@/types/reader';
import type { PagedRendererProps } from './types';
import { PageSlot } from './paged/PageSlot';

const VISIBLE_WINDOW = 2; // pages above/below current to keep mounted

export const PagedRenderer = forwardRef<RendererHandle, PagedRendererProps>(
  function PagedRenderer(props, ref) {
    const { content, location, viewport, invertedDarkMode, onLocationChange, onSelection } = props;
    const containerRef = useRef<HTMLDivElement>(null);
    const [pages, setPages] = useState<Map<number, RenderedPage>>(new Map());

    useEffect(() => {
      let cancelled = false;
      const start = Math.max(0, location.pageIndex - VISIBLE_WINDOW);
      const end = Math.min(content.pageCount - 1, location.pageIndex + VISIBLE_WINDOW);
      (async () => {
        for (let i = start; i <= end; i++) {
          if (cancelled) return;
          try {
            const page = await content.renderPage(i, viewport);
            setPages((prev) => new Map(prev).set(i, page));
          } catch (err) {
            console.error(`Failed to render page ${i}:`, err);
          }
        }
      })();
      return () => { cancelled = true; };
    }, [content, location.pageIndex, viewport]);

    useEffect(() => {
      const handler = () => {
        const sel = document.getSelection();
        if (!sel || sel.isCollapsed) { onSelection(null); return; }
        const text = sel.toString().trim();
        if (!text) { onSelection(null); return; }
        const range = sel.getRangeAt(0);
        const rects = Array.from(range.getClientRects());
        onSelection({
          text,
          location: { kind: 'paged', pageIndex: location.pageIndex },
          rects,
          serialized: { kind: 'paged', pageIndex: location.pageIndex, quadPoints: rectsToQuadPoints(rects) },
        });
      };
      document.addEventListener('selectionchange', handler);
      return () => document.removeEventListener('selectionchange', handler);
    }, [location.pageIndex, onSelection]);

    useImperativeHandle(ref, () => ({
      next: () => {
        const nextIdx = Math.min(content.pageCount - 1, location.pageIndex + 1);
        if (nextIdx !== location.pageIndex) onLocationChange({ kind: 'paged', pageIndex: nextIdx });
      },
      prev: () => {
        const prevIdx = Math.max(0, location.pageIndex - 1);
        if (prevIdx !== location.pageIndex) onLocationChange({ kind: 'paged', pageIndex: prevIdx });
      },
      jumpTo: (loc) => {
        if (loc.kind !== 'paged') return;
        onLocationChange(loc);
      },
      getCurrentLocation: () => ({ kind: 'paged', pageIndex: location.pageIndex }),
      applyHighlights: () => { /* real impl in Task 26 */ },
    }), [content.pageCount, location.pageIndex, onLocationChange]);

    return (
      <div ref={containerRef} style={{ height: '100%', width: '100%', overflowY: 'auto', background: props.theme.bg }}>
        {Array.from(pages.entries())
          .sort(([a], [b]) => a - b)
          .map(([i, page]) => (
            <PageSlot key={i} page={page} invertedDarkMode={invertedDarkMode} />
          ))}
      </div>
    );
  },
);

function rectsToQuadPoints(rects: DOMRect[]): number[] {
  const out: number[] = [];
  for (const r of rects) {
    out.push(r.left, r.top, r.right, r.top, r.left, r.bottom, r.right, r.bottom);
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/renderers/PagedRenderer.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/renderers/PagedRenderer.tsx apps/main/src/components/reader/renderers/PagedRenderer.test.tsx
git commit -m "feat(reader): add PagedRenderer (windowed virtualization, text overlay)"
```

---

## Phase 4: Shell skeleton

### Task 17: Reader font + invert atoms

**Files:**
- Create: `apps/main/src/atoms/reader.ts`

- [ ] **Step 1: Implement atoms**

```typescript
// apps/main/src/atoms/reader.ts
import { atomWithStorage } from 'jotai/utils';
import type { FontSettings } from '@/components/reader/renderers/types';

export const fontSettingsAtom = atomWithStorage<FontSettings>('reader.fontSettings', {
  family: 'Georgia, serif',
  size: 18,
  lineHeight: 1.6,
});

export const invertedDarkModeAtom = atomWithStorage<boolean>('reader.invertedDarkMode', false);
```

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/main && bunx tsc --noEmit`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/atoms/reader.ts
git commit -m "feat(reader): add fontSettings and invertedDarkMode atoms"
```

---

### Task 18: TopBar component

**Files:**
- Create: `apps/main/src/components/reader/TopBar.tsx`

- [ ] **Step 1: Implement TopBar**

```tsx
// apps/main/src/components/reader/TopBar.tsx
import { ListTree, Palette, Highlighter, MessageSquare } from 'lucide-react';
import { IconButton } from '@components/ui/IconButton';
import { BackButton } from '@components/BackButton';
import type { Book } from '@/generated';

export type PanelId = 'toc' | 'settings' | 'highlights' | 'chat';

export interface TopBarProps {
  book: Book;
  progressLabel: string;
  onOpenPanel: (panel: PanelId) => void;
}

export function TopBar({ book, progressLabel, onOpenPanel }: TopBarProps) {
  return (
    <div className="reader-top-bar" style={{
      display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px',
      borderBottom: '1px solid var(--reader-border, #e5e5e5)',
    }}>
      <BackButton />
      <div style={{ flex: 1, overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis' }}>
        {book.title || 'Untitled'}
      </div>
      <div style={{ opacity: 0.7, fontSize: 13 }}>{progressLabel}</div>
      <IconButton aria-label="Table of contents" onClick={() => onOpenPanel('toc')}><ListTree size={18} /></IconButton>
      <IconButton aria-label="Settings"           onClick={() => onOpenPanel('settings')}><Palette size={18} /></IconButton>
      <IconButton aria-label="Highlights"         onClick={() => onOpenPanel('highlights')}><Highlighter size={18} /></IconButton>
      <IconButton aria-label="Chat"               onClick={() => onOpenPanel('chat')}><MessageSquare size={18} /></IconButton>
    </div>
  );
}
```

- [ ] **Step 2: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/reader/TopBar.tsx
git commit -m "feat(reader): add unified TopBar"
```

---

### Task 19: SidePanel and TOCPanel

**Files:**
- Create: `apps/main/src/components/reader/SidePanel.tsx`
- Create: `apps/main/src/components/reader/TOCPanel.tsx`

- [ ] **Step 1: Implement SidePanel using existing Sheet**

```tsx
// apps/main/src/components/reader/SidePanel.tsx
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/components/ui/sheet';
import type { ReactNode } from 'react';

export interface SidePanelProps {
  open: boolean;
  title: string;
  onClose: () => void;
  children: ReactNode;
}

export function SidePanel({ open, title, onClose, children }: SidePanelProps) {
  return (
    <Sheet open={open} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="right">
        <SheetHeader>
          <SheetTitle>{title}</SheetTitle>
        </SheetHeader>
        <div style={{ paddingTop: 12 }}>{children}</div>
      </SheetContent>
    </Sheet>
  );
}
```

- [ ] **Step 2: Implement TOCPanel**

```tsx
// apps/main/src/components/reader/TOCPanel.tsx
import type { TOCEntry, Location } from '@/types/reader';

export interface TOCPanelProps {
  toc: TOCEntry[];
  onJump: (loc: Location) => void;
}

export function TOCPanel({ toc, onJump }: TOCPanelProps) {
  if (toc.length === 0) return <div style={{ opacity: 0.7 }}>No table of contents available.</div>;
  return <ul style={{ listStyle: 'none', paddingLeft: 0 }}>{toc.map((e, i) => <Entry key={i} entry={e} onJump={onJump} depth={0} />)}</ul>;
}

function Entry({ entry, onJump, depth }: { entry: TOCEntry; onJump: (loc: Location) => void; depth: number }) {
  return (
    <li>
      <button
        onClick={() => onJump(entry.location)}
        style={{ paddingLeft: depth * 16, padding: '6px 0', display: 'block', width: '100%', textAlign: 'left', background: 'none', border: 0, cursor: 'pointer' }}
      >
        {entry.title}
      </button>
      {entry.children.length > 0 && (
        <ul style={{ listStyle: 'none', paddingLeft: 0 }}>
          {entry.children.map((c, i) => <Entry key={i} entry={c} onJump={onJump} depth={depth + 1} />)}
        </ul>
      )}
    </li>
  );
}
```

- [ ] **Step 3: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/reader/SidePanel.tsx apps/main/src/components/reader/TOCPanel.tsx
git commit -m "feat(reader): add SidePanel wrapper and TOCPanel"
```

---

### Task 20: BottomBar (TTS controls slot)

**Files:**
- Create: `apps/main/src/components/reader/BottomBar.tsx`

- [ ] **Step 1: Implement BottomBar**

```tsx
// apps/main/src/components/reader/BottomBar.tsx
import type { ReactNode } from 'react';

export function BottomBar({ children }: { children: ReactNode }) {
  return (
    <div className="reader-bottom-bar" style={{
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      padding: '8px 12px', borderTop: '1px solid var(--reader-border, #e5e5e5)',
    }}>
      {children}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/reader/BottomBar.tsx
git commit -m "feat(reader): add BottomBar slot wrapper"
```

---

### Task 21: ReaderShell skeleton (no feature wiring yet)

**Files:**
- Create: `apps/main/src/components/reader/ReaderShell.tsx`
- Test: `apps/main/src/components/reader/ReaderShell.test.tsx`

- [ ] **Step 1: Write failing skeleton test**

```typescript
// apps/main/src/components/reader/ReaderShell.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { ReaderShell } from './ReaderShell';

vi.mock('./adapters/useBookAdapter', () => ({
  useBookAdapter: () => ({
    status: 'ready',
    content: {
      kind: 'reflowable',
      metadata: { tableOfContents: [] },
      chapters: [{ id: 'c1', index: 0, loadHtml: async () => '<p>x</p>' }],
      resolveResource: async () => null,
    },
  }),
}));

const book = {
  id: 1, kind: 'epub', title: 'Test Book', filepath: '/x', location: '', cover: '',
  author: '', publisher: '', version: 1, coverKind: 'fallback',
} as never;

describe('ReaderShell', () => {
  it('renders top bar with book title', () => {
    const { getByText } = render(<ReaderShell book={book} />);
    expect(getByText('Test Book')).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/ReaderShell.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement skeleton ReaderShell**

```tsx
// apps/main/src/components/reader/ReaderShell.tsx
import { useRef, useState } from 'react';
import { useAtomValue } from 'jotai';
import type { Book } from '@/generated';
import type {
  Location, SelectionInfo, Paragraph, RendererHandle, AppliedHighlight, Viewport, BookContent,
} from '@/types/reader';
import { useBookAdapter } from './adapters/useBookAdapter';
import { ReflowableRenderer } from './renderers/ReflowableRenderer';
import { PagedRenderer } from './renderers/PagedRenderer';
import { TopBar, type PanelId } from './TopBar';
import { BottomBar } from './BottomBar';
import { SidePanel } from './SidePanel';
import { TOCPanel } from './TOCPanel';
import { themeAtom } from '@/stores/epub_atoms';
import { themes } from '@/themes/themes';
import { fontSettingsAtom, invertedDarkModeAtom } from '@/atoms/reader';
import { decodeLocation, type BookKind } from '@/utils/location-codec';

export function ReaderShell({ book }: { book: Book }) {
  const adapter = useBookAdapter(book);
  const themeKey = useAtomValue(themeAtom);
  const fontSettings = useAtomValue(fontSettingsAtom);
  const invertedDarkMode = useAtomValue(invertedDarkModeAtom);
  const [location, setLocation] = useState<Location>(() => decodeLocation(book.location, book.kind as BookKind));
  const [, setSelection] = useState<SelectionInfo | null>(null);
  const [, setVisibleParagraphs] = useState<Paragraph[]>([]);
  const [openPanel, setOpenPanel] = useState<PanelId | null>(null);
  const [viewport] = useState<Viewport>({ scale: 1 });
  const rendererRef = useRef<RendererHandle>(null);
  const highlights: AppliedHighlight[] = []; // wired in Task 26

  const themeColors = themes[themeKey];
  const theme = { bg: themeColors.background, fg: themeColors.color, accent: '#06f' };

  return (
    <div className="reader-shell" style={{
      display: 'grid', gridTemplateRows: 'auto 1fr auto',
      height: '100vh', background: theme.bg, color: theme.fg,
    }}>
      <TopBar book={book} progressLabel={progressLabel(adapter, location)} onOpenPanel={setOpenPanel} />
      <div style={{ position: 'relative', overflow: 'hidden' }}>
        {adapter.status === 'loading' && <div style={{ padding: 16 }}>Loading…</div>}
        {adapter.status === 'error' && <div style={{ padding: 16, color: 'crimson' }}>Failed to open: {adapter.error?.message}</div>}
        {adapter.content?.kind === 'reflowable' && location.kind === 'reflowable' && (
          <ReflowableRenderer
            ref={rendererRef}
            content={adapter.content}
            location={location}
            theme={theme}
            fontSettings={fontSettings}
            highlights={highlights}
            onLocationChange={setLocation}
            onVisibleParagraphsChange={setVisibleParagraphs}
            onSelection={setSelection}
          />
        )}
        {adapter.content?.kind === 'paged' && location.kind === 'paged' && (
          <PagedRenderer
            ref={rendererRef}
            content={adapter.content}
            location={location}
            theme={theme}
            viewport={viewport}
            invertedDarkMode={invertedDarkMode}
            highlights={highlights}
            onLocationChange={setLocation}
            onVisibleParagraphsChange={setVisibleParagraphs}
            onSelection={setSelection}
          />
        )}
      </div>
      <BottomBar>{/* TTSControls wired in Task 25 */}</BottomBar>
      <SidePanel
        open={openPanel === 'toc'}
        title="Table of contents"
        onClose={() => setOpenPanel(null)}
      >
        <TOCPanel
          toc={adapter.content?.metadata.tableOfContents ?? []}
          onJump={(loc) => { setLocation(loc); setOpenPanel(null); }}
        />
      </SidePanel>
      {/* Other panels wired in feature tasks */}
    </div>
  );
}

function progressLabel(adapter: { content: BookContent | null }, loc: Location): string {
  if (!adapter.content) return '';
  if (adapter.content.kind === 'paged' && loc.kind === 'paged') {
    return `Page ${loc.pageIndex + 1} of ${adapter.content.pageCount}`;
  }
  if (adapter.content.kind === 'reflowable' && loc.kind === 'reflowable') {
    const total = adapter.content.chapters.length;
    const idx = adapter.content.chapters.findIndex((c) => c.id === loc.chapterId);
    return idx >= 0 ? `Chapter ${idx + 1} of ${total}` : '';
  }
  return '';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/ReaderShell.test.tsx && bun run lint`
Expected: PASS, no lint errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx apps/main/src/components/reader/ReaderShell.test.tsx
git commit -m "feat(reader): add ReaderShell skeleton (no feature wiring yet)"
```

---

## Phase 5: Feature wiring

### Task 22: Keyboard navigation in shell

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`
- Test: `apps/main/src/components/reader/ReaderShell.keyboard.test.tsx`

- [ ] **Step 1: Write failing test**

```typescript
// apps/main/src/components/reader/ReaderShell.keyboard.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from 'vitest-browser-react';
import { ReaderShell } from './ReaderShell';

const next = vi.fn(), prev = vi.fn();

vi.mock('./renderers/ReflowableRenderer', () => ({
  ReflowableRenderer: vi.fn().mockImplementation(({ ref }) => {
    if (ref && typeof ref !== 'function') (ref as { current: unknown }).current = { next, prev, jumpTo: vi.fn(), getCurrentLocation: () => ({ kind: 'reflowable', chapterId: 'c1' }), applyHighlights: vi.fn() };
    return null;
  }),
}));

vi.mock('./adapters/useBookAdapter', () => ({
  useBookAdapter: () => ({
    status: 'ready',
    content: {
      kind: 'reflowable',
      metadata: { tableOfContents: [] },
      chapters: [{ id: 'c1', index: 0, loadHtml: async () => '<p>x</p>' }],
      resolveResource: async () => null,
    },
  }),
}));

const book = { id: 1, kind: 'epub', title: 't', filepath: '/x', location: '', cover: '', author: '', publisher: '', version: 1, coverKind: 'fallback' } as never;

describe('keyboard nav', () => {
  it('ArrowRight calls next', () => {
    render(<ReaderShell book={book} />);
    fireEvent.keyDown(document, { key: 'ArrowRight' });
    expect(next).toHaveBeenCalled();
  });
  it('ArrowLeft calls prev', () => {
    render(<ReaderShell book={book} />);
    fireEvent.keyDown(document, { key: 'ArrowLeft' });
    expect(prev).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/main && bun run test:browser -- src/components/reader/ReaderShell.keyboard.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Add keyboard effect to ReaderShell**

In `apps/main/src/components/reader/ReaderShell.tsx`, add `useEffect` to the React import line and insert this `useEffect` block inside `ReaderShell` (after the existing state declarations):

```typescript
useEffect(() => {
  const handler = (e: KeyboardEvent) => {
    if (openPanel) {
      if (e.key === 'Escape') { setOpenPanel(null); e.preventDefault(); }
      return;
    }
    switch (e.key) {
      case 'ArrowRight':
      case 'PageDown':
      case ' ':
        rendererRef.current?.next();
        e.preventDefault();
        break;
      case 'ArrowLeft':
      case 'PageUp':
        rendererRef.current?.prev();
        e.preventDefault();
        break;
    }
  };
  document.addEventListener('keydown', handler);
  return () => document.removeEventListener('keydown', handler);
}, [openPanel]);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/main && bun run test:browser -- src/components/reader/ReaderShell.keyboard.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx apps/main/src/components/reader/ReaderShell.keyboard.test.tsx
git commit -m "feat(reader): add keyboard navigation to shell"
```

---

### Task 23: Gesture navigation (swipe)

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Add swipe handler**

In `ReaderShell.tsx`, import:

```typescript
import { useDrag } from '@use-gesture/react';
```

Inside the component, add:

```typescript
const swipeBind = useDrag(({ swipe: [swipeX] }) => {
  if (swipeX === -1) rendererRef.current?.next();
  if (swipeX === 1) rendererRef.current?.prev();
});
```

And spread it onto the content wrapper div:

```tsx
<div style={{ position: 'relative', overflow: 'hidden' }} {...swipeBind()}>
```

- [ ] **Step 2: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors. (Manual gesture testing happens in QA matrix.)

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): add swipe navigation"
```

---

### Task 24: Location persistence

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Add debounced location persistence effect**

In `ReaderShell.tsx`, add imports:

```typescript
import { encodeLocation } from '@/utils/location-codec';
import { updateBookLocation } from '@/generated';
import { triggerSyncOnWrite } from '@/modules/sync-triggers';
```

Add this effect inside the component:

```typescript
useEffect(() => {
  const handle = setTimeout(() => {
    void updateBookLocation({ bookId: book.id, location: encodeLocation(location) })
      .then(() => triggerSyncOnWrite())
      .catch((err) => console.error('Failed to save location:', err));
  }, 1000);
  return () => clearTimeout(handle);
}, [book.id, location]);
```

- [ ] **Step 2: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): persist book location on change with sync trigger"
```

---

### Task 25: TTS Player rewiring

**Files:**
- Modify: `apps/main/src/models/PlayerClass.ts`
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read current Player class**

Run: `Read apps/main/src/models/PlayerClass.ts`

Identify the eventBus subscriptions in `initialize()`. They will be replaced with prop-driven setters.

- [ ] **Step 2: Modify Player class — add setters**

In `apps/main/src/models/PlayerClass.ts`, add fields and methods on the `Player` class:

```typescript
public onRequestNextPage: (() => void) | null = null;
public onRequestPrevPage: (() => void) | null = null;

public setVisibleParagraphs(paragraphs: ParagraphWithIndex[]): void {
  if (this.playingState === PlayingState.WaitingForNewParagraphs) {
    this.setPlayingState(PlayingState.Playing);
  }
  if (isEqual(this.currentViewParagraphs, paragraphs)) return;
  this.currentViewParagraphs = paragraphs;
  if (this.playingState === PlayingState.Playing) {
    void this.handleLocationChanged();
  }
}

public setNextPageParagraphs(paragraphs: ParagraphWithIndex[]): void {
  if (isEqual(this.nextPageParagraphs, paragraphs)) return;
  this.nextPageParagraphs = paragraphs;
}

public setPreviousPageParagraphs(paragraphs: ParagraphWithIndex[]): void {
  if (isEqual(this.previousPageParagraphs, paragraphs)) return;
  this.previousPageParagraphs = [...paragraphs].reverse();
}
```

In `moveToNextPage` and `moveToPreviousPage`, replace the relevant `eventBus.publish(...)` calls with callback invocations:

```typescript
private moveToNextPage = async () => {
  this.setPlayingState(PlayingState.WaitingForNewParagraphs);
  this.currentViewParagraphs = this.nextPageParagraphs;
  this.nextPageParagraphs = [];
  this.onRequestNextPage?.();
  await this.stop();
  await this.resetParagraphs();
  await this.play();
};

private moveToPreviousPage = async () => {
  this.setPlayingState(PlayingState.WaitingForNewParagraphs);
  this.currentViewParagraphs = [...this.previousPageParagraphs].reverse();
  this.previousPageParagraphs = [];
  this.onRequestPrevPage?.();
  await this.stop();
  await this.resetParagraphs();
  await this.play();
};
```

In `initialize`, **remove** the four `eventBus.subscribe(...)` lines and the `eventBusSubscriptions` array population. Keep the `removeEventBusSubscriptions` method (now a no-op but harmless until cleanup phase).

- [ ] **Step 3: Wire Player into ReaderShell**

In `apps/main/src/components/reader/ReaderShell.tsx`, add imports:

```typescript
import { Player } from '@/models/PlayerClass';
import TTSControls from '@/components/TTSControls';
```

Inside the component, replace `const [, setVisibleParagraphs] = useState<Paragraph[]>([])` with `const [visibleParagraphs, setVisibleParagraphs] = useState<Paragraph[]>([])`. Add:

```typescript
const audioRef = useRef<HTMLAudioElement | null>(null);
const playerRef = useRef<Player | null>(null);

useEffect(() => {
  if (!audioRef.current) return;
  const player = new Player(audioRef.current);
  playerRef.current = player;
  void player.initialize(String(book.id));
  player.onRequestNextPage = () => rendererRef.current?.next();
  player.onRequestPrevPage = () => rendererRef.current?.prev();
  return () => { player.cleanup(); playerRef.current = null; };
}, [book.id]);

useEffect(() => {
  const mapped = visibleParagraphs.map((p) => ({ text: p.text, index: p.id }));
  playerRef.current?.setVisibleParagraphs(mapped);
}, [visibleParagraphs]);
```

In the JSX, render the audio element and TTSControls inside `BottomBar`:

```tsx
<BottomBar>
  <audio ref={audioRef} />
  {playerRef.current && <TTSControls player={playerRef.current} />}
</BottomBar>
```

(Note: `TTSControls` may not currently accept `player` as a prop. Read `apps/main/src/components/TTSControls.tsx` and adjust either the prop or use a stable singleton + setter. The minimum requirement: TTSControls can call `player.play()`, `player.pause()`, `player.next()`, `player.prev()`.)

- [ ] **Step 4: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 5: Manual smoke test**

Open a route that mounts ReaderShell with a real EPUB. Verify TTS plays and advances. (Captured in QA matrix Task 36.)

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/models/PlayerClass.ts apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): rewire Player to prop-driven paragraph setter"
```

---

### Task 26: Highlight loading and apply

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`
- Modify: `apps/main/src/components/reader/renderers/ReflowableRenderer.tsx`
- Modify: `apps/main/src/components/reader/renderers/PagedRenderer.tsx`

- [ ] **Step 1: Read existing highlight storage API**

Run: `Read apps/main/src/modules/highlight-storage.ts` then `Read apps/main/src/components/highlights/SelectionPopover.tsx`. Note the existing `Highlight` shape and call signatures of `saveHighlight` / `getHighlightsForBook`.

- [ ] **Step 2: Wire highlight loading in shell**

In `ReaderShell.tsx`, add imports:

```typescript
import { getHighlightsForBook } from '@/modules/highlight-storage';
import type { SerializedSelection, AppliedHighlight as AppliedHighlightType } from '@/types/reader';
```

Replace `const highlights: AppliedHighlight[] = [];` with:

```typescript
const [highlightsState, setHighlightsState] = useState<AppliedHighlight[]>([]);

useEffect(() => {
  let cancelled = false;
  void getHighlightsForBook(String(book.id)).then((rows) => {
    if (cancelled) return;
    const applied: AppliedHighlight[] = rows
      .filter((row) => isHighlightForCurrentLocation(row, location))
      .map((row) => ({
        id: String(row.id),
        serialized: deserializeHighlight(row),
        color: row.color,
      }));
    setHighlightsState(applied);
  });
  return () => { cancelled = true; };
}, [book.id, location]);

useEffect(() => {
  rendererRef.current?.applyHighlights(highlightsState);
}, [highlightsState]);
```

Pass `highlights={highlightsState}` to both renderers (replacing `highlights={highlights}`).

Add helper functions at module scope:

```typescript
function isHighlightForCurrentLocation(row: { location: string }, loc: Location): boolean {
  try {
    const stored = JSON.parse(row.location) as SerializedSelection;
    if (loc.kind === 'reflowable' && stored.kind === 'reflowable') return stored.chapterId === loc.chapterId;
    if (loc.kind === 'paged' && stored.kind === 'paged') return stored.pageIndex === loc.pageIndex;
    return false;
  } catch { return false; }
}

function deserializeHighlight(row: { location: string }): SerializedSelection {
  return JSON.parse(row.location) as SerializedSelection;
}
```

(If the existing `Highlight` row shape uses different field names — for example `cfi_range` instead of `location` — adjust the helpers to read the actual field. Read `highlight-storage.ts` and `db.ts` to confirm.)

- [ ] **Step 3: Implement ReflowableRenderer.applyHighlights**

Replace the stub `applyMarks` in `ReflowableRenderer.tsx` with:

```typescript
function applyMarks(root: ShadowRoot, highlights: { id: string; serialized: SerializedSelection; color: string }[]): void {
  // Clear previous marks
  root.querySelectorAll('mark[data-highlight-id]').forEach((el) => {
    const parent = el.parentNode;
    if (!parent) return;
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.removeChild(el);
  });

  for (const h of highlights) {
    if (h.serialized.kind !== 'reflowable') continue;
    const range = rangeFromSerialized(root, h.serialized.cfiRange);
    if (!range) continue;
    try {
      const mark = document.createElement('mark');
      mark.setAttribute('data-highlight-id', h.id);
      mark.style.background = h.color;
      mark.style.color = 'inherit';
      range.surroundContents(mark);
    } catch {
      // Range crosses element boundaries; skip for v1 (track as orphan in shell)
    }
  }
}

function rangeFromSerialized(root: ShadowRoot, serialized: string): Range | null {
  const [, rest] = serialized.split('::');
  if (!rest) return null;
  const [startSpec, endSpec] = rest.split('/');
  const startNode = nodeFromPath(root, startSpec.split(':')[0]);
  const endNode = nodeFromPath(root, endSpec.split(':')[0]);
  const startOffset = Number(startSpec.split(':')[1]);
  const endOffset = Number(endSpec.split(':')[1]);
  if (!startNode || !endNode) return null;
  const range = document.createRange();
  try {
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
    return range;
  } catch { return null; }
}

function nodeFromPath(root: ShadowRoot, path: string): Node | null {
  let current: Node = root;
  for (const segment of path.split('/').filter(Boolean)) {
    const idx = Number(segment);
    if (!current.childNodes[idx]) return null;
    current = current.childNodes[idx];
  }
  return current;
}
```

- [ ] **Step 4: Implement PagedRenderer.applyHighlights**

In `PagedRenderer.tsx`, add:

```typescript
import type { AppliedHighlight } from '@/types/reader';

const [appliedHighlights, setAppliedHighlights] = useState<AppliedHighlight[]>([]);
```

Update `useImperativeHandle`:

```typescript
applyHighlights: (highlights) => setAppliedHighlights(highlights),
```

In the JSX, wrap each PageSlot with an overlay layer:

```tsx
{Array.from(pages.entries())
  .sort(([a], [b]) => a - b)
  .map(([i, page]) => (
    <div key={i} style={{ position: 'relative' }}>
      <PageSlot page={page} invertedDarkMode={invertedDarkMode} />
      <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
        {appliedHighlights
          .filter((h) => h.serialized.kind === 'paged' && h.serialized.pageIndex === i)
          .map((h) => h.serialized.kind === 'paged' ? (
            <div key={h.id}>
              {quadPointsToRects(h.serialized.quadPoints).map((rect, j) => (
                <div key={j} style={{
                  position: 'absolute',
                  left: rect.x, top: rect.y, width: rect.w, height: rect.h,
                  background: h.color, opacity: 0.4, mixBlendMode: 'multiply',
                }} />
              ))}
            </div>
          ) : null)}
      </div>
    </div>
  ))}
```

Add helper:

```typescript
function quadPointsToRects(quadPoints: number[]): { x: number; y: number; w: number; h: number }[] {
  const out: { x: number; y: number; w: number; h: number }[] = [];
  for (let i = 0; i + 7 < quadPoints.length; i += 8) {
    const x = quadPoints[i];
    const y = quadPoints[i + 1];
    const w = quadPoints[i + 2] - x;
    const h = quadPoints[i + 5] - y;
    out.push({ x, y, w, h });
  }
  return out;
}
```

- [ ] **Step 5: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 6: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx apps/main/src/components/reader/renderers/ReflowableRenderer.tsx apps/main/src/components/reader/renderers/PagedRenderer.tsx
git commit -m "feat(reader): load and apply highlights for current location"
```

---

### Task 27: SelectionPopover integration

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read SelectionPopover API**

Run: `Read apps/main/src/components/highlights/SelectionPopover.tsx`. Note the prop names it accepts.

- [ ] **Step 2: Add popover with save handler**

In `ReaderShell.tsx`, change `const [, setSelection]` back to `const [selection, setSelection] = useState<SelectionInfo | null>(null);`. Add imports:

```typescript
import { SelectionPopover } from '@/components/highlights/SelectionPopover';
import { saveHighlight } from '@/modules/highlight-storage';
```

Extract a refresh helper above the JSX:

```typescript
const refreshHighlights = useCallback(async () => {
  const rows = await getHighlightsForBook(String(book.id));
  setHighlightsState(rows
    .filter((row) => isHighlightForCurrentLocation(row, location))
    .map((row) => ({ id: String(row.id), serialized: deserializeHighlight(row), color: row.color })));
}, [book.id, location]);
```

Add `useCallback` to the React imports.

Inside the content area JSX, alongside the renderers:

```tsx
{selection && (
  <SelectionPopover
    cfiRange={selection.serialized.kind === 'reflowable' ? selection.serialized.cfiRange : ''}
    text={selection.text}
    position={selection.rects[0]
      ? { x: selection.rects[0].left, y: selection.rects[0].top }
      : { x: 0, y: 0 }}
    onColor={async (color: string) => {
      await saveHighlight({
        bookId: String(book.id),
        location: JSON.stringify(selection.serialized),
        text: selection.text,
        color,
      });
      await refreshHighlights();
      setSelection(null);
    }}
    onClose={() => setSelection(null)}
  />
)}
```

(Adjust prop names if SelectionPopover's API differs. The shell's responsibility is to feed it the selection coordinates and the save handler.)

- [ ] **Step 3: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): wire SelectionPopover to save highlights from any format"
```

---

### Task 28: Settings panel with contextual controls

**Files:**
- Modify: `apps/main/src/components/reader/ReaderSettings.tsx`
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read current ReaderSettings**

Run: `Read apps/main/src/components/reader/ReaderSettings.tsx`

- [ ] **Step 2: Replace ReaderSettings with contextual version**

```tsx
// apps/main/src/components/reader/ReaderSettings.tsx
import { useAtom } from 'jotai';
import { themeAtom } from '@/stores/epub_atoms';
import { fontSettingsAtom, invertedDarkModeAtom } from '@/atoms/reader';
import { themes } from '@/themes/themes';

export function ReaderSettings({ contentKind }: { contentKind: 'reflowable' | 'paged' }) {
  const [theme, setTheme] = useAtom(themeAtom);
  const [fontSettings, setFontSettings] = useAtom(fontSettingsAtom);
  const [inverted, setInverted] = useAtom(invertedDarkModeAtom);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <section>
        <h3 style={{ margin: 0, fontSize: 14 }}>Theme</h3>
        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
          {Object.keys(themes).map((key) => (
            <button key={key} onClick={() => setTheme(key as never)}
                    style={{ padding: 8, border: theme === key ? '2px solid currentColor' : '1px solid #ccc' }}>
              {key}
            </button>
          ))}
        </div>
      </section>

      {contentKind === 'reflowable' && (
        <section>
          <h3 style={{ margin: 0, fontSize: 14 }}>Font</h3>
          <label>Size <input type="range" min={12} max={28} value={fontSettings.size}
            onChange={(e) => setFontSettings({ ...fontSettings, size: Number(e.target.value) })} /></label>
          <label>Line height <input type="range" min={1.2} max={2.0} step={0.1} value={fontSettings.lineHeight}
            onChange={(e) => setFontSettings({ ...fontSettings, lineHeight: Number(e.target.value) })} /></label>
          <label>Family
            <select value={fontSettings.family} onChange={(e) => setFontSettings({ ...fontSettings, family: e.target.value })}>
              <option value="Georgia, serif">Serif</option>
              <option value="system-ui, sans-serif">Sans-serif</option>
              <option value="ui-monospace, monospace">Monospace</option>
            </select>
          </label>
        </section>
      )}

      {contentKind === 'paged' && (
        <section>
          <label><input type="checkbox" checked={inverted} onChange={(e) => setInverted(e.target.checked)} />
            {' '}Dark mode for pages (inverts colors)</label>
        </section>
      )}
    </div>
  );
}
```

- [ ] **Step 3: Wire ReaderSettings into shell**

In `ReaderShell.tsx`, add import:

```typescript
import { ReaderSettings } from './ReaderSettings';
```

Add a settings panel:

```tsx
<SidePanel open={openPanel === 'settings'} title="Settings" onClose={() => setOpenPanel(null)}>
  <ReaderSettings contentKind={adapter.content?.kind ?? 'reflowable'} />
</SidePanel>
```

- [ ] **Step 4: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/reader/ReaderSettings.tsx apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): wire contextual settings (font for reflowable, invert for paged)"
```

---

### Task 29: HighlightsPanel and ChatPanel wiring

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read existing panel APIs**

Run: `Read apps/main/src/components/highlights/HighlightsPanel.tsx`
Run: `Read apps/main/src/components/chat/ChatPanel.tsx`

- [ ] **Step 2: Wire panels in shell**

Add imports:

```typescript
import { HighlightsPanel } from '@/components/highlights/HighlightsPanel';
import { ChatPanel } from '@/components/chat/ChatPanel';
```

Add to JSX:

```tsx
<SidePanel open={openPanel === 'highlights'} title="Highlights" onClose={() => setOpenPanel(null)}>
  <HighlightsPanel
    bookId={String(book.id)}
    onJump={(loc: string) => {
      try {
        const parsed = JSON.parse(loc) as Location;
        setLocation(parsed);
        setOpenPanel(null);
      } catch { /* malformed; ignore */ }
    }}
  />
</SidePanel>

<SidePanel open={openPanel === 'chat'} title="Chat" onClose={() => setOpenPanel(null)}>
  <ChatPanel
    bookId={String(book.id)}
    seedSelection={selection ? { text: selection.text } : undefined}
  />
</SidePanel>
```

(Adapt prop names to actual panel APIs. If `HighlightsPanel`/`ChatPanel` don't currently accept these exact props, extend them or add a thin wrapper that accepts the new shape.)

- [ ] **Step 3: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): wire HighlightsPanel and ChatPanel into shell"
```

---

### Task 30: Cover image generation for paged formats

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read existing cover update util**

Run: `Read apps/main/src/components/pdf/utils/updateStoredCoverImage.tsx`

- [ ] **Step 2: Add cover effect to shell**

Add import:

```typescript
import { updateStoredCoverImage } from '@/components/pdf/utils/updateStoredCoverImage';
import type { PagedContent } from '@/types/reader';
```

Add effect:

```typescript
useEffect(() => {
  if (!adapter.content || adapter.content.kind !== 'paged') return;
  if (book.coverKind !== 'fallback') return;
  let cancelled = false;
  (async () => {
    try {
      const content = adapter.content as PagedContent;
      const page = await content.renderPage(0, { scale: 0.3 });
      if (cancelled) return;
      let blob: Blob;
      if (page.source.kind === 'canvas') {
        blob = await new Promise<Blob>((resolve, reject) =>
          page.source.kind === 'canvas'
            ? page.source.canvas.toBlob((b) => b ? resolve(b) : reject(new Error('toBlob failed')), 'image/png')
            : reject(new Error('not canvas')),
        );
      } else {
        const res = await fetch(page.source.url);
        blob = await res.blob();
      }
      await updateStoredCoverImage(book.id, blob);
    } catch (err) {
      console.error('Cover gen failed:', err);
    }
  })();
  return () => { cancelled = true; };
}, [adapter.content, book.id, book.coverKind]);
```

- [ ] **Step 3: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): consolidate cover generation into shell"
```

---

### Task 31: RAG embedding job consolidation

**Files:**
- Modify: `apps/main/src/components/reader/ReaderShell.tsx`

- [ ] **Step 1: Read existing embedding-job triggers**

Run: `Grep "processEpubJob" apps/main/src` to find current callers and signatures.

Run: `Read apps/main/src/modules/process_epub.ts`

- [ ] **Step 2: Add single embedding-job effect**

Add imports:

```typescript
import { processEpubJob } from '@/modules/process_epub';
import { hasSavedEpubData } from '@/generated';
```

Add effect (adjust args to match actual `processEpubJob` signature):

```typescript
useEffect(() => {
  if (!adapter.content) return;
  let cancelled = false;
  (async () => {
    const has = await hasSavedEpubData({ bookId: book.id }).catch(() => false);
    if (cancelled || has) return;
    await processEpubJob(book.id /* additional args per current signature */).catch((err) => {
      console.error('Embedding job failed:', err);
    });
  })();
  return () => { cancelled = true; };
}, [adapter.content, book.id]);
```

(The current per-format embedding triggers in `MobiView`/`DjvuView` will be deleted in Task 33. The shell's effect supersedes them.)

- [ ] **Step 3: Verify build**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/components/reader/ReaderShell.tsx
git commit -m "feat(reader): consolidate RAG embedding job into shell"
```

---

## Phase 6: Cutover

### Task 32: Cutover the route

**Files:**
- Modify: `apps/main/src/routes/books.$id.lazy.tsx`

- [ ] **Step 1: Replace the route's render branch**

In `BookView`, replace:

```tsx
{book?.kind === "pdf" && <PdfView ... />}
{book?.kind === "epub" && <EpubView ... />}
{book?.kind === "mobi" && <MobiView ... />}
{book?.kind === "djvu" && <DjvuView ... />}
```

with:

```tsx
{book && <ReaderShell key={book.id} book={book} />}
```

Update imports — remove `EpubView`, `PdfView`, `MobiView`, `DjvuView`; add `ReaderShell`:

```typescript
import { ReaderShell } from '@/components/reader/ReaderShell';
```

- [ ] **Step 2: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: No errors. All tests PASS.

- [ ] **Step 3: Manual smoke test**

Run dev server. Open one book of each format. Verify each renders and basic navigation works.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/routes/books.$id.lazy.tsx
git commit -m "feat(reader): cut over books route to ReaderShell"
```

---

### Task 33: Delete old view files

**Files:**
- Delete: `apps/main/src/components/epub.tsx`
- Delete: `apps/main/src/components/pdf/components/pdf.tsx`
- Delete: `apps/main/src/components/mobi/MobiView.tsx`
- Delete: `apps/main/src/components/djvu/DjvuView.tsx`
- Delete: `apps/main/src/components/react-reader/` (entire directory)

- [ ] **Step 1: Delete files**

```bash
rm apps/main/src/components/epub.tsx
rm apps/main/src/components/pdf/components/pdf.tsx
rm apps/main/src/components/mobi/MobiView.tsx
rm apps/main/src/components/djvu/DjvuView.tsx
rm -r apps/main/src/components/react-reader
```

- [ ] **Step 2: Verify nothing imports them**

Run: `cd apps/main && bunx tsc --noEmit`
Expected: No errors. If "Cannot find module" appears for utilities re-exported from these files, follow the error and update consumers.

- [ ] **Step 3: Run full test suite**

Run: `cd apps/main && bun run test`
Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add -A apps/main/src/components/
git commit -m "chore(reader): delete legacy format view components"
```

---

### Task 34: Delete legacy player-control abstraction

**Files:**
- Delete: `apps/main/src/models/player_control.ts`
- Delete: `apps/main/src/models/epub_player_contol.ts`
- Delete: `apps/main/src/models/pdf_player_control.ts`

- [ ] **Step 1: Delete files**

```bash
rm apps/main/src/models/player_control.ts apps/main/src/models/epub_player_contol.ts apps/main/src/models/pdf_player_control.ts
```

- [ ] **Step 2: Find and remove orphan imports**

Run: `Grep "epub_player_contol\|pdf_player_control\|player_control" apps/main/src`
Expected: zero matches. If any, edit those files to remove dead imports.

If `ParagraphWithIndex` was imported from `player_control.ts` by `models/PlayerClass.ts`, inline its definition into `PlayerClass.ts`:

```typescript
export type ParagraphWithIndex = { text: string; index: string };
```

- [ ] **Step 3: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add -A apps/main/src/models/
git commit -m "chore(reader): remove legacy PlayerControl abstraction"
```

---

### Task 35: Remove npm dependencies

**Files:**
- Modify: `apps/main/package.json`

- [ ] **Step 1: Verify @react-pdf/renderer is unused**

Run: `Grep "@react-pdf/renderer" apps/main/src`
Expected: zero matches. If matches exist, **do not remove the dep** — note them and leave it. Otherwise proceed.

- [ ] **Step 2: Remove deps**

```bash
cd apps/main && bun remove react-pdf react-reader
# Only if Step 1 found zero matches:
cd apps/main && bun remove @react-pdf/renderer
```

- [ ] **Step 3: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: All PASS. If any imports fail, those references were missed earlier — fix and re-run.

- [ ] **Step 4: Commit**

```bash
git add apps/main/package.json apps/main/bun.lockb
git commit -m "chore(reader): remove react-pdf and react-reader dependencies"
```

---

### Task 36: Run the manual QA matrix

**Files:**
- Reference: `docs/superpowers/specs/2026-04-16-unified-reader-qa-matrix.md`

- [ ] **Step 1: Build the production bundle**

Run: `cd apps/main && bun run build`
Expected: Build succeeds.

- [ ] **Step 2: Walk every cell in the QA matrix**

Open `docs/superpowers/specs/2026-04-16-unified-reader-qa-matrix.md`. For each format × scenario cell, perform the action and mark PASS or FAIL with a note in a working copy. Don't commit until all rows pass.

If any cell fails: stop and fix. Each failure becomes its own commit (with a regression test where possible) before re-running the matrix.

- [ ] **Step 3: Commit the completed matrix**

```bash
git add docs/superpowers/specs/2026-04-16-unified-reader-qa-matrix.md
git commit -m "test(reader): record passing manual QA matrix"
```

---

## Phase 7: Cleanup (post-cutover)

### Task 37: Migrate epubwrapper.ts logic into useEpubAdapter

**Files:**
- Modify: `apps/main/src/components/reader/adapters/useEpubAdapter.ts`
- Delete: `apps/main/src/epubwrapper.ts` (only if zero remaining importers)

- [ ] **Step 1: Find remaining importers**

Run: `Grep "from.*epubwrapper" apps/main/src`

- [ ] **Step 2: For each remaining importer, migrate the function it needs**

Move utility functions from `epubwrapper.ts` into `useEpubAdapter.ts` as private helpers, or into a sibling `epub-helpers.ts` if broadly used.

- [ ] **Step 3: Delete epubwrapper.ts when empty**

```bash
rm apps/main/src/epubwrapper.ts
rm apps/main/src/epubwrapper.browser.test.tsx  # if obsoleted
```

- [ ] **Step 4: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add -A apps/main/src/
git commit -m "refactor(reader): fold epubwrapper into useEpubAdapter"
```

---

### Task 38: Move PDF hooks into reader/renderers/paged/

**Files:**
- Move: `apps/main/src/components/pdf/hooks/useScrolling.tsx` → `apps/main/src/components/reader/renderers/paged/useScrolling.ts`
- Move: `apps/main/src/components/pdf/hooks/useVirualization.tsx` → `apps/main/src/components/reader/renderers/paged/useVirtualization.ts` (also fixes the typo)
- Move: `apps/main/src/components/pdf/hooks/useCurrentPageNumber.tsx` → `apps/main/src/components/reader/renderers/paged/useCurrentPageNumber.ts`
- Delete: `apps/main/src/components/pdf/hooks/useUpdateCoverIMage.tsx` (logic was inlined in Task 30)

- [ ] **Step 1: Use git mv for each file**

```bash
cd apps/main
git mv src/components/pdf/hooks/useScrolling.tsx           src/components/reader/renderers/paged/useScrolling.ts
git mv src/components/pdf/hooks/useVirualization.tsx       src/components/reader/renderers/paged/useVirtualization.ts
git mv src/components/pdf/hooks/useCurrentPageNumber.tsx   src/components/reader/renderers/paged/useCurrentPageNumber.ts
rm src/components/pdf/hooks/useUpdateCoverIMage.tsx
```

- [ ] **Step 2: Update imports**

Run: `Grep "from .*pdf/hooks" apps/main/src` and update each match to the new location. Update `PagedRenderer.tsx` to import from the new location if it doesn't already.

- [ ] **Step 3: Delete the now-empty pdf/ directory tree**

```bash
find apps/main/src/components/pdf -type d -empty -delete
```

- [ ] **Step 4: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add -A apps/main/src/components/
git commit -m "refactor(reader): relocate paged-renderer hooks under reader/"
```

---

### Task 39: Delete legacy event-bus paragraph events

**Files:**
- Modify: `apps/main/src/utils/bus.ts`

- [ ] **Step 1: Identify unused events**

Run: `Grep "NEW_PARAGRAPHS_AVAILABLE\|NEXT_VIEW_PARAGRAPHS_AVAILABLE\|PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE\|NEXT_PAGE_PARAGRAPHS_EMPTIED\|PREVIOUS_PAGE_PARAGRAPHS_EMPTIED\|PAGE_CHANGED" apps/main/src`

- [ ] **Step 2: Remove the unused entries from `EventBusEvent` and the eventBus type map**

Other events used elsewhere (`PLAYING_AUDIO`, `MOVED_TO_NEXT_PARAGRAPH`, `MOVED_TO_PREV_PARAGRAPH`, `PLAYING_STATE_CHANGED`, etc.) stay.

- [ ] **Step 3: Verify build + tests**

Run: `cd apps/main && bunx tsc --noEmit && bun run lint && bun run test`
Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/utils/bus.ts
git commit -m "chore(reader): drop unused paragraph eventBus events"
```

---

## Final verification

### Task 40: Full test suite + production build + Sentry monitoring

- [ ] **Step 1: Full test suite**

Run: `cd apps/main && bun run test && bun run test:browser`
Expected: All PASS.

- [ ] **Step 2: Production build**

Run: `cd apps/main && bun run build`
Expected: Builds successfully.

- [ ] **Step 3: Verify bundle does not contain react-pdf / react-reader**

Run after build: `cd apps/main && grep -r "react-pdf\|react-reader" dist/` (or whatever the output dir is)
Expected: zero matches. If any, an unintended import remains; track it down.

- [ ] **Step 4: Production preview smoke pass**

Run: appropriate Tauri preview command for this project. Verify: open one book per format, basic navigation, TTS, highlight save, theme switch. Compare against pre-cutover behavior.

- [ ] **Step 5: Tag the cutover for easy rollback reference**

```bash
git tag -a unified-reader-cutover -m "Unified reader cutover landed"
```

- [ ] **Step 6: Post-merge monitoring (manual checklist for the next 48h)**

Watch Sentry for errors with stack frames in `components/reader/`, `models/PlayerClass.ts`, or any reader-related module. File issues for any regression seen.

---

## Self-review checklist

- [ ] Every spec section maps to at least one task: architecture → Tasks 1-21; security model → Tasks 3, 11; content model → Task 1; renderers → Tasks 10-16; adapters → Tasks 4-9; shell + integration → Tasks 17-31; migration → Tasks 32-36; cleanup → Tasks 37-39; risks all have mitigations.
- [ ] No "TBD"/"TODO" placeholders. The `applyMarks` stub in Task 14 explicitly references its replacement task (26) and pairs with non-crashing default behavior.
- [ ] Type names referenced in later tasks match definitions in Task 1 (`BookContent`, `Location`, `Paragraph`, `SelectionInfo`, `SerializedSelection`, `RendererHandle`, `AppliedHighlight`, `Viewport`, `RenderedPage`) and Task 10 (`Theme`, `FontSettings`, renderer prop types). Used consistently.
- [ ] Imperative handle method names consistent across renderers and shell: `next`, `prev`, `jumpTo`, `getCurrentLocation`, `applyHighlights`.
- [ ] Each task ends with a commit step.
- [ ] Cutover (Task 32) follows all feature wiring (Tasks 22-31), so the new path is feature-complete before the old is deleted.
- [ ] Manual QA matrix (Task 36) gates cleanup phase.
