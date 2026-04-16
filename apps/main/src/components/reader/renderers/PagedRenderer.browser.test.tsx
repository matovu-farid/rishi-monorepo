// apps/main/src/components/reader/renderers/PagedRenderer.browser.test.tsx
import { describe, it, expect, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { PagedRenderer } from './PagedRenderer';
import type { PagedContent, Location, Paragraph, SelectionInfo } from '@/types/reader';

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
    const { container } = await render(
      <PagedRenderer
        content={fakeContent}
        location={{ kind: 'paged', pageIndex: 0 }}
        theme={{ bg: '#fff', fg: '#000', accent: '#06f' }}
        viewport={{ scale: 1 }}
        invertedDarkMode={false}
        highlights={[]}
        onLocationChange={(_loc: Location) => {}}
        onVisibleParagraphsChange={(_paragraphs: Paragraph[]) => {}}
        onSelection={(_selection: SelectionInfo | null) => {}}
      />,
    );
    await new Promise((r) => setTimeout(r, 200));
    expect(container.querySelector('canvas')).toBeTruthy();
  });
});
