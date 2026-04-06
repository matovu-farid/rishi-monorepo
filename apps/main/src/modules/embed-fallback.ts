import { embed } from '@/generated/commands';
import type { EmbedParam, EmbedResult } from '@/generated/types';
import { load } from '@tauri-apps/plugin-store';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';

async function embedTextsOnServer(texts: string[]): Promise<number[][]> {
  const store = await load('store.json');
  const token = await store.get<string>('auth_token');
  if (!token) throw new Error('No auth token for server embedding');
  const response = await fetch(`${WORKER_URL}/api/embed`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ texts }),
  });
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
