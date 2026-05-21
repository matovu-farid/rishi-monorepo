/**
 * Helper to populate `playerStore.currentParagraphs` from the RAG chunker
 * output. The new TTS player consumes `ParagraphWithIndex` shaped data;
 * the chunker hands back `TextChunk` rows with `{ id, text }`. The shapes
 * are isomorphic — this helper is just a tiny adapter that:
 *
 *   1. Calls `getChunks(filePath, format, bookId)` once.
 *   2. Maps `{ id, text } → { index: id, text }`.
 *   3. Writes the result to `usePlayerStore.setState({ currentParagraphs })`.
 *
 * For EPUB/MOBI/AZW3 the chunker uses the existing extractors. For PDF
 * the reader supplies its own paragraphs via the WebView (see
 * `lib/pdf/read-aloud-from-selection.ts`); this helper isn't used there.
 * DJVU follows EPUB/MOBI semantics — single chunk list, no per-page
 * partitioning at the reader layer.
 */
import { usePlayerStore } from '@/lib/stores/playerStore'
import { getChunks } from '@/lib/rag/chunker'
import type { ParagraphWithIndex } from '@rishi/shared/machines/playerMachine'

export interface SeedResult {
  paragraphs: ParagraphWithIndex[]
  /** True when at least one non-empty chunk was found and seeded. */
  seeded: boolean
}

/**
 * Load chunks for `(bookId, filePath, format)` and write them to the
 * playerStore. Returns the seeded list (empty if extraction yielded no
 * chunks).
 */
export async function seedPlayerParagraphsFromChunks(
  bookId: string,
  filePath: string,
  format: string,
): Promise<SeedResult> {
  const chunks = await getChunks(filePath, format, bookId)
  const paragraphs: ParagraphWithIndex[] = chunks
    .filter((c) => c.text.trim().length > 0)
    .map((c) => ({ index: c.id, text: c.text }))

  usePlayerStore.setState({ currentParagraphs: paragraphs })
  return { paragraphs, seeded: paragraphs.length > 0 }
}
