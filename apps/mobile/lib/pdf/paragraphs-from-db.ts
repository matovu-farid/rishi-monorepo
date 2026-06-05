import { rawDb } from '@/lib/db'

export interface ParagraphRow { index: string; text: string }

export function paragraphsForPage(bookId: string, pageNumber: number): ParagraphRow[] {
  return rawDb.getAllSync<{ paragraph_index: string; text: string }>(
    `SELECT paragraph_index, text FROM book_paragraphs
       WHERE book_id='${bookId.replace(/'/g, "''")}' AND page_number=${pageNumber}
       ORDER BY paragraph_index`,
  ).map((r) => ({ index: r.paragraph_index, text: r.text }))
}
