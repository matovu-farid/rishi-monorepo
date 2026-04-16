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
    void (async () => {
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
      const rawPage = await getDjvuPage({ path: filepath, pageNumber: pageIndex, dpi });
      // getDjvuPage returns number[] (raw bytes); cast via mock in tests, convert to Blob in production
      const blob = rawPage instanceof Blob
        ? rawPage
        : new Blob([new Uint8Array(rawPage as unknown as number[])], { type: 'image/png' });
      const url = URL.createObjectURL(blob);
      const rawText = await getDjvuPageText({ path: filepath, pageNumber: pageIndex }).catch(() => [] as string[]);
      let width = 0;
      let height = 0;
      try {
        const bitmap = await createImageBitmap(blob);
        width = bitmap.width;
        height = bitmap.height;
        bitmap.close();
      } catch {
        // bitmap dimensions unavailable (e.g. in test environments with stub blobs)
      }
      const page: RenderedPage = {
        source: { kind: 'blob', url },
        textItems: (rawText as string[]).map((text): TextItem => ({
          text,
          bbox: { x: 0, y: 0, width: 0, height: 0 },
        })),
        width,
        height,
      };
      cache.set(pageIndex, page);
      return page;
    },
  };
}
