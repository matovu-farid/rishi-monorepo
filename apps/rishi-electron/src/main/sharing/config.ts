import type { SharingConfig } from '../../preload/ipc-contract.js'

export function getSharingConfig(): SharingConfig {
  const wsBaseUrl = process.env.RISHI_SHARING_WS_URL ?? 'wss://sharing.rishi.fidexa.org'
  const workerBaseUrl = process.env.RISHI_SHARING_WORKER_URL ?? 'https://sharing.rishi.fidexa.org'
  return {
    wsBaseUrl,
    workerBaseUrl,
    iceServers: [
      { urls: 'stun:stun.cloudflare.com:3478' },
      { urls: 'stun:stun.l.google.com:19302' }
    ]
  }
}
