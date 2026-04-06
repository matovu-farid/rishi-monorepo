import { apiClient } from '@/lib/api'

/**
 * Embed texts using the server-side OpenAI embedding endpoint.
 * Used as fallback when on-device embedding is impractical (bulk imports).
 *
 * @param texts - Array of text strings to embed
 * @returns Array of 384-dimension embedding vectors
 */
export async function embedTextsOnServer(texts: string[]): Promise<number[][]> {
  const response = await apiClient('/api/embed', {
    method: 'POST',
    body: JSON.stringify({ texts }),
  })

  if (!response.ok) {
    const errorBody = await response.text().catch(() => 'Unknown error')
    throw new Error(`Server embedding failed (${response.status}): ${errorBody}`)
  }

  const data = await response.json() as { embeddings: number[][] }
  return data.embeddings
}
