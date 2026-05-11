import type {
  RagService,
  RagServiceDeps,
  SemanticChunk,
} from './types'

const EMBEDDING_DIM = 384
const indexName = (bookId: number): string => `${bookId}-vectordb`

export function createRagService(deps: RagServiceDeps): RagService {
  const { ipc, embed } = deps

  return {
    async searchSemantic(query, bookId, k) {
      if (query.trim().length === 0) return []
      const vector = await embed(query)
      const hits = await ipc.searchVectors(indexName(bookId), vector, EMBEDDING_DIM, k)
      const chunks = await Promise.all(hits.map((h) => ipc.getTextFromVectorId(h.id)))
      const result: SemanticChunk[] = []
      for (let i = 0; i < hits.length; i++) {
        const chunk = chunks[i]
        if (!chunk) continue
        result.push({
          chunkId: chunk.id,
          bookId: chunk.bookId,
          pageNumber: chunk.pageNumber,
          text: chunk.data,
          distance: hits[i].distance,
        })
      }
      return result
    },
    async searchText(_query, _bookId) {
      throw new Error('not implemented')
    },
    async isIndexed(_bookId) {
      throw new Error('not implemented')
    },
  }
}
