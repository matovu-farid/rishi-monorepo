/**
 * Embed Fallback for Electron
 *
 * Tries on-device embedding via the main process (@xenova/transformers) first.
 * If that fails, falls back to the server-side Worker API endpoint.
 * Mirrors the Tauri embed-fallback implementation.
 */

import type { EmbedParam, EmbedResult } from '@/lib/api'
import { getAuthToken } from './auth'

const WORKER_URL = 'https://api.fidexa.org'

/**
 * Send texts to the server for embedding when on-device fails.
 */
async function embedTextsOnServer(texts: string[]): Promise<number[][]> {
  const token = await getAuthToken()
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 30_000)

  let response: Response
  try {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json'
    }
    if (token) {
      headers['Authorization'] = `Bearer ${token}`
    } else {
      // Try dev bypass secret when no auth token available
      const devBypass = await window.electron.getDevBypassSecret()
      if (devBypass) {
        headers['X-Dev-Bypass'] = devBypass
      } else {
        throw new Error('Not authenticated: no auth token or dev bypass available')
      }
    }

    response = await fetch(`${WORKER_URL}/api/embed`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ texts }),
      signal: controller.signal
    })
  } catch (err) {
    if (controller.signal.aborted) {
      throw new Error('Embed request timed out after 30 seconds')
    }
    throw err
  } finally {
    clearTimeout(timeout)
  }

  if (!response.ok) {
    throw new Error(`Server embed failed: ${response.status}`)
  }

  const data = (await response.json()) as { embeddings: number[][] }
  return data.embeddings
}

/**
 * Generate embeddings with fallback:
 * 1. Try on-device embedding via Electron main process (Transformers.js)
 * 2. If that fails, fall back to the Worker server endpoint
 */
export async function embedWithFallback(embedParams: EmbedParam[]): Promise<EmbedResult[]> {
  try {
    // Try on-device embedding first via the main process IPC
    return await window.electron.embed(embedParams)
  } catch (err) {
    console.warn('[embed-fallback] On-device failed, using server fallback:', err)

    const texts = embedParams.map((p) => p.text)
    const serverEmbeddings = await embedTextsOnServer(texts)

    return serverEmbeddings.map((vec, i) => ({
      dim: vec.length,
      embedding: vec,
      text: embedParams[i].text,
      metadata: embedParams[i].metadata
    }))
  }
}

export async function embedSingleText(text: string): Promise<number[]> {
  const results = await embedWithFallback([
    { text, metadata: { id: 0, pageNumber: 0, bookId: 0 } },
  ])
  if (!results[0]) throw new Error('Embed returned empty result')
  return results[0].embedding
}
