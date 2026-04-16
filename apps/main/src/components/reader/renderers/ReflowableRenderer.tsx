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
      if (!container || !chapter || !html) return;
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
      // Use a small delay so ChapterFrame shadow DOM has time to render
      const initialTimer = setTimeout(handler, 50);
      return () => {
        container.removeEventListener('scroll', debounced);
        clearTimeout(initialTimer);
      };
    }, [chapter, html, columnWidth, onLocationChange, onVisibleParagraphsChange]);

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
    const parent: ParentNode = current.parentNode;
    const idx = Array.prototype.indexOf.call(parent.childNodes, current);
    parts.unshift(String(idx));
    current = parent;
  }
  return parts.join('/');
}

function applyMarks(root: ShadowRoot, highlights: { id: string; serialized: SerializedSelection; color: string }[]): void {
  // Clear previous marks by unwrapping them back to plain text nodes
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
      // Range crosses element boundaries — skip for v1
    }
  }
}

function rangeFromSerialized(root: ShadowRoot, serialized: string): Range | null {
  const [, rest] = serialized.split('::');
  if (!rest) return null;
  const [startSpec, endSpec] = rest.split('/');
  if (!startSpec || !endSpec) return null;
  const startParts = startSpec.split(':');
  const endParts = endSpec.split(':');
  const startNode = nodeFromPath(root, startParts[0]);
  const endNode = nodeFromPath(root, endParts[0]);
  const startOffset = Number(startParts[1]);
  const endOffset = Number(endParts[1]);
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
