import { describe, it, expect, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { ReaderShell } from './ReaderShell';

const next = vi.fn(), prev = vi.fn();

vi.mock('./renderers/ReflowableRenderer', () => ({
  ReflowableRenderer: vi.fn().mockImplementation((props: { ref?: { current: unknown } | ((r: unknown) => void) }) => {
    const handle = { next, prev, jumpTo: vi.fn(), getCurrentLocation: () => ({ kind: 'reflowable', chapterId: 'c1' }), applyHighlights: vi.fn() };
    if (typeof props.ref === 'function') props.ref(handle);
    else if (props.ref) (props.ref as { current: unknown }).current = handle;
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

// TopBar uses BackButton which requires @tanstack/react-router context; mock it away
vi.mock('./TopBar', () => ({
  TopBar: ({ book }: { book: { title: string }; progressLabel: string; onOpenPanel: () => void }) => (
    <div data-testid="top-bar">{book.title}</div>
  ),
}));

// epub_atoms has Tauri-invoked side effects at module load time; provide a plain jotai atom
vi.mock('@/stores/epub_atoms', async () => {
  const { atom } = await import('jotai');
  return { themeAtom: atom('white') };
});

const book = { id: 1, kind: 'epub', title: 't', filepath: '/x', location: '', cover: '', author: '', publisher: '', version: 1, coverKind: 'fallback' } as never;

describe('keyboard nav', () => {
  it('ArrowRight calls next', async () => {
    await render(<ReaderShell book={book} />);
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
    expect(next).toHaveBeenCalled();
  });
  it('ArrowLeft calls prev', async () => {
    await render(<ReaderShell book={book} />);
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft' }));
    expect(prev).toHaveBeenCalled();
  });
});
