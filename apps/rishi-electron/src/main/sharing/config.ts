import type { SharingConfig } from '../../preload/ipc-contract.js'

/**
 * Resolve the sharing worker config. Both names are accepted for the worker URL:
 *  - `SHARING_WORKER_URL` (preferred, used by Plan 3 E2E harness)
 *  - `RISHI_SHARING_WORKER_URL` (legacy, kept for backward compatibility)
 * Falls back to the production URL when neither is set.
 */
export function getSharingConfig(): SharingConfig {
  const wsBaseUrl = process.env.RISHI_SHARING_WS_URL ?? 'wss://sharing.rishi.fidexa.org'
  const workerBaseUrl =
    process.env.SHARING_WORKER_URL ??
    process.env.RISHI_SHARING_WORKER_URL ??
    'https://sharing.rishi.fidexa.org'
  return {
    wsBaseUrl,
    workerBaseUrl,
    iceServers: [
      { urls: 'stun:stun.cloudflare.com:3478' },
      { urls: 'stun:stun.l.google.com:19302' }
    ]
  }
}
