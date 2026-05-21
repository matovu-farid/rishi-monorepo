/**
 * Format-agnostic TTS reconciler primitive for mobile.
 *
 * The mobile readers render paragraph-shaped content per format:
 *   - PDF: react-native-pdf renders the original pages; we overlay a
 *     paragraph-strip below or above the page that highlights the
 *     currently-playing chunk.
 *   - MOBI / AZW3: a WebView renders the parsed HTML. We dispatch the
 *     chunk index into the WebView and CSS marks the matching element.
 *   - DJVU: same pattern as MOBI/AZW3 — WebView + injected message.
 *   - EPUB: epubjs-react-native + an injected stylesheet keyed on a
 *     CFI / chunk index.
 *
 * What this module owns: turning an `activeParagraph` (from `playerStore`)
 * into a single chunk-index integer the reader's render layer can apply.
 * Each format passes a small adapter (a list of chunks + a "find chunk
 * by paragraph index" function) so the reconciler stays pure and
 * unit-testable in jest's node env.
 */

import type { ParagraphWithIndex } from '@/lib/stores/playerStore'

export interface ChunkLike {
  /** Stable identifier (matches the player's paragraph.index). */
  id: string
  /** 0-based ordinal in the book's chunk list. */
  chunkIndex: number
}

export interface ReconcileResult {
  /** -1 means "no highlight" — clear any existing visual cue. */
  activeChunkIndex: number
  /** The chunk id used to reach the index, or null when none. */
  activeChunkId: string | null
}

/**
 * Pure reconciliation. Given the player's currently-active paragraph and
 * the format's chunk list, decide which chunk should be highlighted.
 *
 * Matching is identity-first (`chunk.id === paragraph.index`). If no
 * chunk matches the paragraph's index verbatim, returns -1 silently —
 * the reader's UI clears any existing highlight. This matches electron's
 * "silent recovery" semantics in `reconcileAzw3TtsHighlight`.
 */
export function reconcileTtsHighlight(
  chunks: readonly ChunkLike[],
  activeParagraph: ParagraphWithIndex | null,
): ReconcileResult {
  if (!activeParagraph) {
    return { activeChunkIndex: -1, activeChunkId: null }
  }
  const match = chunks.find((c) => c.id === activeParagraph.index)
  if (!match) {
    return { activeChunkIndex: -1, activeChunkId: null }
  }
  return { activeChunkIndex: match.chunkIndex, activeChunkId: match.id }
}
