import { useEffect } from 'react'
import { useTextEmbeddings, ALL_MINILM_L6_V2 } from 'react-native-executorch'
import { setEmbeddingForward } from '@/lib/rag/embedder'

export function useEmbeddingModel() {
  const model = useTextEmbeddings({ model: ALL_MINILM_L6_V2 })

  useEffect(() => {
    if (model.isReady) {
      // Register the forward function so non-hook code (pipeline) can embed.
      //
      // react-native-executorch returns a `Float32Array` (its type was
      // widened in a recent release). The downstream contract (lib/rag/
      // embedder + the worker fallback) is `number[]`, so we materialize
      // the typed array via `Array.from`. The double-cast through
      // `unknown` is required because TS sees Float32Array and number[]
      // as not-sufficiently-overlapping when the runtime gives us the
      // typed-array branch.
      setEmbeddingForward(async (text: string) => {
        const result = (await model.forward(text)) as unknown
        if (Array.isArray(result)) return result as number[]
        return Array.from(result as Float32Array)
      })
    }
  }, [model.isReady, model.forward])

  return {
    isReady: model.isReady,
    downloadProgress: model.downloadProgress,
  }
}
