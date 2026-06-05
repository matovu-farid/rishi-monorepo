import { rawDb } from '@/lib/db'

export interface ParagraphRow { index: string; text: string }

function safeInt(n: number, label: string): number {
  if (!Number.isInteger(n)) {
    throw new TypeError(`[sql] ${label} must be an integer, got ${typeof n}: ${String(n)}`)
  }
  return n
}

export function paragraphsForPage(bookId: string, pageNumber: number): ParagraphRow[] {
  return rawDb.getAllSync<{ paragraph_index: string; text: string }>(
    `SELECT paragraph_index, text FROM book_paragraphs
       WHERE book_id='${bookId.replace(/'/g, "''")}' AND page_number=${safeInt(pageNumber, 'pageNumber')}
       ORDER BY paragraph_index`,
  ).map((r) => ({ index: r.paragraph_index, text: r.text }))
}
