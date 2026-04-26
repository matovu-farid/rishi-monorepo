// ---------------------------------------------------------------------------
// Embeddings module — local sentence embeddings via @xenova/transformers
// ---------------------------------------------------------------------------

type Pipeline = Awaited<ReturnType<typeof import('@xenova/transformers').pipeline>>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MODEL_NAME = 'Xenova/all-MiniLM-L6-v2'
const BATCH_SIZE = 32
const EXPECTED_DIM = 384

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

/** Cached pipeline instance (lazy-loaded on first call). */
let pipelineInstance: Pipeline | null = null
let pipelineLoading: Promise<Pipeline> | null = null

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Return the feature-extraction pipeline, creating it on the first call.
 *
 * The model weights are downloaded from HuggingFace on first use and cached
 * locally by the transformers library.
 */
async function getPipeline(): Promise<Pipeline> {
  if (pipelineInstance) return pipelineInstance

  // Prevent duplicate initialisation when multiple callers race
  if (pipelineLoading) return pipelineLoading

  pipelineLoading = (async () => {
    try {
      const { pipeline } = await import('@xenova/transformers')
      const pipe = await pipeline('feature-extraction', MODEL_NAME, {
        // Quantised model for faster inference
        quantized: true
      })
      pipelineInstance = pipe
      return pipe
    } catch (err) {
      // Reset so subsequent calls can retry
      pipelineLoading = null
      throw new Error(
        `Failed to load the embedding model "${MODEL_NAME}". ` +
          `This may be caused by a network issue during the initial model ` +
          `download. Original error: ${err instanceof Error ? err.message : String(err)}`
      )
    }
  })()

  return pipelineLoading
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface EmbeddingInput {
  text: string
  metadata: {
    id: number
    pageNumber: number
    bookId: number
  }
}

export interface EmbeddingResult {
  dim: number
  embedding: number[]
  text: string
  metadata: {
    id: number
    pageNumber: number
    bookId: number
  }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Generate 384-dimensional sentence embeddings for a list of text inputs.
 *
 * Texts are processed in batches of 32 to balance throughput and memory
 * usage. The underlying model (`Xenova/all-MiniLM-L6-v2`) is downloaded on
 * the first invocation and cached locally.
 *
 * @param texts - Objects containing the text to embed along with metadata
 *                that is passed through unmodified.
 * @returns Embedding results in the same order as the input, each containing
 *          the 384-dim vector, the original text, and its metadata.
 */
/** Reset the cached pipeline — used only in tests. */
export function _resetForTesting(): void {
  pipelineInstance = null
  pipelineLoading = null
}

export async function generateEmbeddings(texts: EmbeddingInput[]): Promise<EmbeddingResult[]> {
  if (texts.length === 0) return []

  const pipe = await getPipeline()
  const results: EmbeddingResult[] = []

  // Process in batches
  for (let i = 0; i < texts.length; i += BATCH_SIZE) {
    const batch = texts.slice(i, i + BATCH_SIZE)
    const sentences = batch.map((t) => t.text)

    // Run the pipeline. For feature-extraction the output is a Tensor with
    // shape [batch, tokens, dim]. When called with `{ pooling: 'mean',
    // normalize: true }` the library handles pooling, but not all versions
    // support these options — so we handle it manually for robustness.
    const output = await pipe(sentences, {
      pooling: 'mean',
      normalize: true
    })

    // `output.data` is a flat Float32Array. Determine per-sentence size
    // from the tensor shape: [batchSize, dim] after pooling.
    const batchSize = batch.length
    const dim = output.dims[output.dims.length - 1] ?? EXPECTED_DIM

    for (let j = 0; j < batchSize; j++) {
      const start = j * dim
      const end = start + dim
      const embedding = Array.from(output.data.slice(start, end) as Float32Array)

      results.push({
        dim,
        embedding,
        text: batch[j].text,
        metadata: batch[j].metadata
      })
    }
  }

  return results
}
