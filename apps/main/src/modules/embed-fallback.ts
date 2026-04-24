import { embed } from '@/generated/commands';
import type { EmbedParam, EmbedResult } from '@/generated/types';
import { getAuthToken } from './auth';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';

async function embedTextsOnServer(texts: string[]): Promise<number[][]> {
  const token = await getAuthToken();
  const embedController = new AbortController();
  const embedTimeout = setTimeout(() => embedController.abort(), 30_000);
  let response: Response;
  try {
    response = await fetch(`${WORKER_URL}/api/embed`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ texts }),
      signal: embedController.signal,
    });
  } catch (err) {
    if (embedController.signal.aborted) {
      throw new Error('Embed request timed out after 30 seconds');
    }
    throw err;
  } finally {
    clearTimeout(embedTimeout);
  }
  if (!response.ok) throw new Error(`Server embed failed: ${response.status}`);
  const data = (await response.json()) as { embeddings: number[][] };
  return data.embeddings;
}

export async function embedWithFallback(embedParams: EmbedParam[]): Promise<EmbedResult[]> {
  try {
    return await embed({ embedparams: embedParams });
  } catch (err) {
    console.warn('[embed-fallback] On-device failed, using server fallback:', err);
    const texts = embedParams.map((p) => p.text);
    const serverEmbeddings = await embedTextsOnServer(texts);
    return serverEmbeddings.map((vec, i) => ({
      dim: vec.length,
      embedding: vec,
      text: embedParams[i].text,
      metadata: embedParams[i].metadata,
    }));
  }
}
