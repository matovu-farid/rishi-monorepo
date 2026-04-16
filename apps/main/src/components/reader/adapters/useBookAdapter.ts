import type { Book } from '@/generated';
import type { AdapterState } from '@/types/reader';
import { useEpubAdapter } from './useEpubAdapter';
import { useMobiAdapter } from './useMobiAdapter';
import { usePdfAdapter } from './usePdfAdapter';
import { useDjvuAdapter } from './useDjvuAdapter';

// Hooks-in-conditional is safe here: book.kind is stable for a given route mount.
// The route component remounts (via key={book.id}) when switching books.
export function useBookAdapter(book: Book): AdapterState {
  switch (book.kind) {
    case 'epub': return useEpubAdapter(book.filepath);
    case 'mobi': return useMobiAdapter(book.filepath);
    case 'pdf':  return usePdfAdapter(book.filepath);
    case 'djvu': return useDjvuAdapter(book.filepath);
    default:
      throw new Error(`Unknown book kind: ${book.kind}`);
  }
}
