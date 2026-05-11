import type { AuthHeader, TtsConfig } from './types'

export class TtsTransportError extends Error {
  constructor(
    message: string,
    public readonly status: number | null,
    public readonly retryable: boolean,
    public readonly retryAfterMs: number | null
  ) {
    super(message)
    this.name = 'TtsTransportError'
  }
}

export interface FetchAudioArgs {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  auth: AuthHeader
  config: TtsConfig
  text: string
}

const TTS_MAX_INPUT_CHARS = 4000
const TTS_TIMEOUT_MS = 30_000

function buildHeaders(auth: AuthHeader): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (auth.kind === 'bearer') headers['Authorization'] = `Bearer ${auth.token}`
  else headers['X-Dev-Bypass'] = auth.secret
  return headers
}

export async function fetchAudio(args: FetchAudioArgs): Promise<ArrayBuffer> {
  const { fetch, auth, config, text } = args
  const truncated =
    text.length > TTS_MAX_INPUT_CHARS ? text.slice(0, TTS_MAX_INPUT_CHARS) + '…' : text
  const body = JSON.stringify({
    voice: 'alloy',
    input: truncated,
    response_format: 'mp3',
    speed: 1.0
  })

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), TTS_TIMEOUT_MS)
  let response: Response
  try {
    response = await fetch(config.audioWorkerUrl, {
      method: 'POST',
      headers: buildHeaders(auth),
      body,
      signal: controller.signal
    })
  } finally {
    clearTimeout(timeout)
  }

  if (!response.ok) {
    const errorBody = await response.text().catch(() => '')
    const retryAfterRaw = response.headers.get('Retry-After')
    const retryAfterMs = retryAfterRaw ? Number(retryAfterRaw) * 1000 : null
    const retryable = response.status === 429 || response.status >= 500
    throw new TtsTransportError(
      `TTS API error ${response.status} ${response.statusText} - ${errorBody.slice(0, 500)}`,
      response.status,
      retryable,
      Number.isFinite(retryAfterMs) ? retryAfterMs : null
    )
  }

  const bytes = await response.arrayBuffer()
  if (bytes.byteLength === 0) {
    throw new TtsTransportError(
      'TTS API returned empty audio buffer',
      response.status,
      false,
      null
    )
  }
  return bytes
}
