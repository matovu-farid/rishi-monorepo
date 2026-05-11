import type { RagService, RagServiceDeps } from './types'

export function createRagService(_deps: RagServiceDeps): RagService {
  return {
    async searchSemantic(_query, _bookId, _k) {
      throw new Error('not implemented')
    },
    async searchText(_query, _bookId) {
      throw new Error('not implemented')
    },
    async isIndexed(_bookId) {
      throw new Error('not implemented')
    },
  }
}
