// apps/main/src/components/reader/renderers/ReflowableRenderer.browser.test.tsx
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
        onVisibleParagraphsChange={(paragraphs: unknown[]) => onParagraphs(paragraphs)}
        onSelection={() => {}}
      />
    </div>
  );
}

describe('ReflowableRenderer', () => {
  it('mounts the requested chapter and emits paragraphs', async () => {
    const onParagraphs = vi.fn();
    await render(<Harness onParagraphs={onParagraphs} />);
    await new Promise((r) => setTimeout(r, 200));
    const calls = onParagraphs.mock.calls.flat();
    expect(calls.some((c: unknown) => Array.isArray(c) && c.length > 0)).toBe(true);
  });
});
