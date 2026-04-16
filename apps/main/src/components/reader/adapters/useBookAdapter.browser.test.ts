import { describe, it, expect, vi } from 'vitest';
import { renderHook } from 'vitest-browser-react';
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
  ] as const)('dispatches %s to %s adapter', async (kind, expectedKind) => {
    const book = { id: 1, kind, filepath: '/x' } as never;
    const { result } = await renderHook(() => useBookAdapter(book));
    expect(result.current.content?.kind).toBe(expectedKind);
  });
});
