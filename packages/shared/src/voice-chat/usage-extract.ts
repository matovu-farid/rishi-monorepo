import type { RealtimeUsageInput } from '@rishi/shared/billing/realtime-usage-accumulator'

/**
 * Extract a RealtimeUsageInput from a raw OpenAI Realtime `response.done`
 * transport event. The shape mirrors the server contract:
 *
 *   response.usage.input_tokens
 *   response.usage.input_token_details.{audio_tokens,text_tokens}
 *   response.usage.output_tokens
 *   response.usage.output_token_details.{audio_tokens,text_tokens}
 *
 * Returns null when the event is not parseable as response.done usage —
 * callers should skip without throwing.
 */
export function extractUsageFromResponseDone(event: unknown): RealtimeUsageInput | null {
  if (!event || typeof event !== 'object') return null
  const e = event as { type?: unknown; response?: unknown }
  if (e.type !== 'response.done') return null
  const response = e.response
  if (!response || typeof response !== 'object') return null
  const usage = (response as { usage?: unknown }).usage
  if (!usage || typeof usage !== 'object') return null

  const u = usage as {
    input_token_details?: unknown
    output_token_details?: unknown
  }
  const inDet = (u.input_token_details ?? {}) as { audio_tokens?: unknown; text_tokens?: unknown }
  const outDet = (u.output_token_details ?? {}) as { audio_tokens?: unknown; text_tokens?: unknown }

  return {
    audioInputTokens: numberOrZero(inDet.audio_tokens),
    textInputTokens: numberOrZero(inDet.text_tokens),
    audioOutputTokens: numberOrZero(outDet.audio_tokens),
    textOutputTokens: numberOrZero(outDet.text_tokens)
  }
}

function numberOrZero(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : 0
}
