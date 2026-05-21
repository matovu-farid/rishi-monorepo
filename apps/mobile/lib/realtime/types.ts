export interface RealtimeSessionHandle {
  pc: any // RTCPeerConnection from react-native-webrtc
  dc: any // RTCDataChannel
  stream: any // MediaStream
  bookId: string
  onGuardrailTriggered?: () => void
  onSessionEnded?: () => void
  onError?: (error: Error) => void
  onStatusChange?: (status: RealtimeStatus) => void
}

export interface RealtimeConfig {
  bookId: string
  onGuardrailTriggered?: () => void
  onSessionEnded?: () => void
  onError?: (error: Error) => void
  onStatusChange?: (status: RealtimeStatus) => void
}

export type RealtimeStatus = 'idle' | 'connecting' | 'active' | 'speaking' | 'ending'

export interface ServerEvent {
  type: string
  [key: string]: any
}

// Tool definitions sent via session.update
export const BOOK_CONTEXT_TOOL = {
  type: 'function' as const,
  name: 'bookContext',
  description:
    'Retrieve relevant information from the book the user is currently reading based on their question. Use this tool when the user asks a question about the book to get the specific context needed to provide an accurate and helpful answer.',
  parameters: {
    type: 'object',
    properties: {
      queryText: {
        type: 'string',
        description: 'The user query to search book content for',
      },
    },
    required: ['queryText'],
  },
}

export const END_CONVERSATION_TOOL = {
  type: 'function' as const,
  name: 'endConversation',
  description: 'End the conversation with the user.',
  parameters: {
    type: 'object',
    properties: {
      reason: {
        type: 'string',
        description: 'Reason for ending the conversation',
      },
    },
    required: ['reason'],
  },
}

/**
 * Pre-Batch-4: this file held a 100-line divergent system prompt. That
 * was the root cause of behavioural drift between mobile and electron
 * voice chat. Batch 4 deletes that prompt; the canonical
 * INSTRUCTIONS_TEMPLATE now lives in
 * `@rishi/shared/voice-chat/build-realtime-agent.ts` and is rendered
 * via `renderRealtimeInstructions(...)`.
 *
 * The legacy `session.ts` consumes the shared template via the
 * `renderLegacyRealtimeInstructions` helper below so the existing
 * `realtime.test.ts` suite (which exercises the old code path)
 * continues to pass.
 *
 * Production code does NOT use this — the Batch 4 `useVoiceChat`
 * hook drives the shared service through `lib/voice-chat/*`.
 */
import { renderRealtimeInstructions } from '@rishi/shared/voice-chat/build-realtime-agent'

export function renderLegacyRealtimeInstructions(): string {
  return renderRealtimeInstructions({ pageText: '', language: 'en' })
}

/** @deprecated Use `renderRealtimeInstructions` from
 * `@rishi/shared/voice-chat/build-realtime-agent` instead. Kept as a
 * default-rendered string for any consumer still importing this name. */
export const REALTIME_AGENT_INSTRUCTIONS = renderLegacyRealtimeInstructions()
