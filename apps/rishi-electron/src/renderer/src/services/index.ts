import { createRagService, type RagService } from './rag'
import { embedSingleText } from '@/modules/embed-fallback'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook,
      },
      embed: embedSingleText,
    })
  }
  return _rag
}
