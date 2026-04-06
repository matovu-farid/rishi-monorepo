import { useEffect } from 'react'
import { useTextEmbeddings, ALL_MINILM_L6_V2 } from 'react-native-executorch'
import { setEmbeddingForward } from '@/lib/rag/embedder'

export function useEmbeddingModel() {
  const model = useTextEmbeddings({ model: ALL_MINILM_L6_V2 })

  useEffect(() => {
    if (model.isReady) {
      // Register the forward function so non-hook code (pipeline) can embed
      setEmbeddingForward(async (text: string) => {
        const result = await model.forward(text)
        return result as number[]
      })
    }
  }, [model.isReady, model.forward])

  return {
    isReady: model.isReady,
    downloadProgress: model.downloadProgress,
  }
}
