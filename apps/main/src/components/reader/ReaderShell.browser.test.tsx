// apps/main/src/components/reader/ReaderShell.browser.test.tsx
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

const book = {
  id: 1, kind: 'epub', title: 'Test Book', filepath: '/x', location: '', cover: '',
  author: '', publisher: '', version: 1, coverKind: 'fallback',
} as never;

describe('ReaderShell', () => {
  it('renders top bar with book title', async () => {
    const { getByText } = await render(<ReaderShell book={book} />);
    expect(getByText('Test Book')).toBeTruthy();
  });
});
