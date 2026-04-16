// apps/main/src/components/reader/renderers/paged/PageSlot.browser.test.tsx
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
    const { container } = await render(<PageSlot page={page} invertedDarkMode={false} />);
    expect(container.querySelector('canvas')).toBeTruthy();
  });

  it('renders a blob page as <img>', async () => {
    const url = URL.createObjectURL(new Blob(['x'], { type: 'image/png' }));
    const page: RenderedPage = {
      source: { kind: 'blob', url },
      textItems: [],
      width: 100, height: 200,
    };
    const { container } = await render(<PageSlot page={page} invertedDarkMode={false} />);
    const img = container.querySelector('img') as HTMLImageElement;
    expect(img.src).toBe(url);
    URL.revokeObjectURL(url);
  });

  it('applies inverted filter when invertedDarkMode is true', async () => {
    const canvas = document.createElement('canvas');
    const page: RenderedPage = {
      source: { kind: 'canvas', canvas },
      textItems: [],
      width: 10, height: 10,
    };
    const { container } = await render(<PageSlot page={page} invertedDarkMode={true} />);
    const layer = container.querySelector('.page-image-layer') as HTMLElement;
    expect(layer.style.filter).toContain('invert');
  });

  it('overlays text items as positioned spans', async () => {
    const canvas = document.createElement('canvas');
    const page: RenderedPage = {
      source: { kind: 'canvas', canvas },
      textItems: [{ text: 'hi', bbox: { x: 10, y: 20, width: 30, height: 12 } }],
      width: 100, height: 100,
    };
    const { container } = await render(<PageSlot page={page} invertedDarkMode={false} />);
    const span = container.querySelector('.page-text-layer span') as HTMLElement;
    expect(span.textContent).toBe('hi');
    expect(span.style.left).toBe('10px');
  });
});
