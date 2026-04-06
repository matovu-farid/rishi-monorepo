// This module wraps the react-native-executorch embedding model.
// The model instance is managed by the useTextEmbeddings hook in the component layer.
// For the pipeline (non-hook context), we need a way to call forward().
// Strategy: export a setter that the hook calls to register the forward function.

let _forward: ((text: string) => Promise<number[]>) | null = null

export function setEmbeddingForward(fn: (text: string) => Promise<number[]>): void {
  _forward = fn
}

export function isEmbeddingReady(): boolean {
  return _forward !== null
}

export async function embedBatch(texts: string[]): Promise<number[][]> {
  if (!_forward) {
    throw new Error('Embedding model not ready. Call setEmbeddingForward first.')
  }
  const results: number[][] = []
  for (const text of texts) {
    const embedding = await _forward(text)
    results.push(embedding)
  }
  return results
}

export async function embedSingle(text: string): Promise<number[]> {
  if (!_forward) {
    throw new Error('Embedding model not ready. Call setEmbeddingForward first.')
  }
  return _forward(text)
}
