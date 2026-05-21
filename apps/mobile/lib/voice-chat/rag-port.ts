/**
 * Mobile RAG port. Wraps the existing on-device vector store /
 * embedder so the voice-chat agent's `bookContext` tool can use the
 * same retrieval path text chat uses.
 */
import type { VoiceChatRagPort } from '@rishi/shared/voice-chat'
import { searchSimilarChunks } from '@/lib/rag/vector-store'
import { embedBatch, isEmbeddingReady } from '@/lib/rag/embedder'
import { embedTextsOnServer } from '@/lib/rag/server-fallback'

/**
 * Build the mobile RAG port. The shared service consumes only
 * `searchSemantic(query, bookId, k)` — we delegate to the existing
 * embedder + sqlite-vec search pipeline.
 *
 * `bookId` in voice-chat is a `number` (electron's IDs are numeric);
 * the mobile store keys are strings. We coerce via `String(bookId)`
 * which matches the existing realtime-session code path.
 */
export function createMobileRagPort(): VoiceChatRagPort {
  return {
    async searchSemantic(
      query: string,
      bookId: number,
      k: number
    ): Promise<Array<{ text: string }>> {
      // Embed the query — prefer on-device, fall back to worker.
      let queryVector: number[]
      if (isEmbeddingReady()) {
        const result = await embedBatch([query])
        queryVector = result[0]
      } else {
        const result = await embedTextsOnServer([query])
        queryVector = result[0]
      }

      const chunks = searchSimilarChunks(String(bookId), queryVector, k) as Array<{
        text: string
      }>
      return chunks.map((c) => ({ text: c.text }))
    }
  }
}
