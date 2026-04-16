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
      void (async () => {
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
