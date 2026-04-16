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
    const { canvas } = page.source;
    while (container.firstChild) container.removeChild(container.firstChild);
    container.appendChild(canvas);
    return () => {
      try { container.removeChild(canvas); } catch { /* already detached */ }
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
