/**
 * Mobile IPC port — talks to the same Cloudflare Worker endpoints
 * electron uses, just via `apiClient` (mobile's session-token-aware
 * fetch wrapper).
 */
import type { VoiceChatIpc } from '@rishi/shared/voice-chat'
import { apiClient } from '@/lib/api'

export const mobileVoiceChatIpc: VoiceChatIpc = {
  async getRealtimeClientSecret(language: string): Promise<string> {
    const response = await apiClient(
      `/api/realtime/client_secrets?language=${encodeURIComponent(language)}`
    )
    if (!response.ok) {
      const body = await response.text().catch(() => '')
      throw new Error(`Worker /api/realtime/client_secrets ${response.status}: ${body}`)
    }
    const data = (await response.json()) as { client_secret?: { value?: string } }
    const secret = data.client_secret?.value
    if (!secret) {
      throw new Error('No client_secret in worker response')
    }
    return secret
  },

  async transcribeAudio(blob: Blob): Promise<string> {
    // The buffered-speech-replay feature is OFF on mobile (no
    // MediaRecorder). This implementation exists so the contract is
    // satisfied and tests can mock it; the activation pipeline never
    // actually calls it because `createMediaRecorder` is omitted from
    // the MediaPort.
    const response = await apiClient('/api/audio/transcribe', {
      method: 'POST',
      headers: {
        'Content-Type': blob.type || 'audio/webm'
      },
      body: blob as unknown as BodyInit
    })
    if (!response.ok) {
      const body = await response.text().catch(() => '')
      throw new Error(`Worker /api/audio/transcribe ${response.status}: ${body}`)
    }
    const data = (await response.json()) as { transcript?: string }
    return data.transcript ?? ''
  }
}
