/**
 * Per-format reader-route resolver (P1-A).
 *
 * Mobile has four reader screens — `/reader/<id>` (EPUB), `/reader/pdf/<id>`,
 * `/reader/mobi/<id>`, and `/reader/djvu/<id>`. Multiple call sites need
 * to derive the right URL from a Book; centralising the branch here
 * means the Library tap target and the in-chat "Source" citation tap
 * agree.
 *
 * AZW3 files share the MOBI reader on mobile (same parser) — R2 also
 * stores them under the mobi key. Treat them identically when routing.
 */
import type { Book } from '@/types/book'

export type ReaderRoute =
  | `/reader/${string}`
  | `/reader/pdf/${string}`
  | `/reader/mobi/${string}`
  | `/reader/djvu/${string}`

export function resolveReaderRouteForBook(book: Pick<Book, 'id' | 'format'>): ReaderRoute {
  switch (book.format) {
    case 'pdf':
      return `/reader/pdf/${book.id}`
    case 'mobi':
    case 'azw3':
      return `/reader/mobi/${book.id}`
    case 'djvu':
      return `/reader/djvu/${book.id}`
    case 'epub':
    default:
      return `/reader/${book.id}`
  }
}
