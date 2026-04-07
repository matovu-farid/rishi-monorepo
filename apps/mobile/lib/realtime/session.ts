import { RTCPeerConnection, mediaDevices } from 'react-native-webrtc'
import { Platform, PermissionsAndroid } from 'react-native'
import { apiClient } from '@/lib/api'
import { searchSimilarChunks } from '@/lib/rag/vector-store'
import { embedBatch, isEmbeddingReady } from '@/lib/rag/embedder'
import { embedTextsOnServer } from '@/lib/rag/server-fallback'
import { checkGuardrail } from './guardrails'
import {
  RealtimeSessionHandle,
  RealtimeConfig,
  ServerEvent,
  BOOK_CONTEXT_TOOL,
  END_CONVERSATION_TOOL,
  REALTIME_AGENT_INSTRUCTIONS,
} from './types'

let activeSession: RealtimeSessionHandle | null = null

/**
 * Request microphone permission at runtime.
 * On Android: uses PermissionsAndroid API.
 * On iOS: getUserMedia triggers the system permission dialog automatically.
 */
async function requestMicrophonePermission(): Promise<void> {
  if (Platform.OS === 'android') {
    const result = await PermissionsAndroid.request(
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
      {
        title: 'Microphone Permission',
        message:
          'This app needs microphone access for voice conversations with AI.',
        buttonPositive: 'Allow',
        buttonNegative: 'Deny',
      }
    )
    if (result !== PermissionsAndroid.RESULTS.GRANTED) {
      throw new Error('Microphone permission denied')
    }
  }
  // iOS: no runtime request needed -- mediaDevices.getUserMedia triggers system dialog
}

/**
 * Create and connect a new realtime voice session via WebRTC.
 */
export async function createRealtimeSession(
  config: RealtimeConfig
): Promise<RealtimeSessionHandle> {
  // a. Get ephemeral key from Worker
  const response = await apiClient('/api/realtime/client_secrets')
  const { client_secret } = await response.json()
  const clientSecret: string = client_secret.value

  // b. Create RTCPeerConnection (no ICE config -- OpenAI handles TURN)
  const pc = new RTCPeerConnection({})

  // c. Create data channel
  const dc = pc.createDataChannel('oai-events')

  // d. Request microphone permission before accessing audio
  await requestMicrophonePermission()

  // e. Get user media
  const stream = await mediaDevices.getUserMedia({ audio: true })

  // f. Add tracks to peer connection
  stream.getTracks().forEach((track: any) => pc.addTrack(track, stream))

  // g. Create and set local description
  const offer = await pc.createOffer({})
  await pc.setLocalDescription(offer)

  // h. Send SDP to OpenAI
  const sdpResponse = await fetch(
    'https://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${clientSecret}`,
        'Content-Type': 'application/sdp',
      },
      body: offer.sdp,
    }
  )
  const answerSdp = await sdpResponse.text()
  await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp })

  // Build handle
  const handle: RealtimeSessionHandle = {
    pc,
    dc,
    stream,
    bookId: config.bookId,
    onGuardrailTriggered: config.onGuardrailTriggered,
    onSessionEnded: config.onSessionEnded,
    onError: config.onError,
    onStatusChange: config.onStatusChange,
  }

  // i. Set up dc open handler: send session config + initial greeting
  // react-native-webrtc's RTCDataChannel uses event-target-shim internally
  // but TS types don't expose onopen/addEventListener — use any cast
  ;(dc as any).onopen = () => {
    // Send session.update with tools and instructions
    dc.send(
      JSON.stringify({
        type: 'session.update',
        session: {
          tools: [BOOK_CONTEXT_TOOL, END_CONVERSATION_TOOL],
          instructions: REALTIME_AGENT_INSTRUCTIONS,
        },
      })
    )

    // Send initial greeting
    dc.send(
      JSON.stringify({
        type: 'conversation.item.create',
        item: {
          type: 'message',
          role: 'user',
          content: [
            {
              type: 'input_text',
              text: 'Please greet the user and ask what you can help with regarding the book they are reading.',
            },
          ],
        },
      })
    )

    // Trigger response
    dc.send(JSON.stringify({ type: 'response.create' }))
  }

  // j. Set up dc message handler: parse JSON and dispatch
  ;(dc as any).onmessage = (event: { data: string }) => {
    try {
      const serverEvent: ServerEvent = JSON.parse(event.data)
      handleServerEvent(serverEvent, handle)
    } catch (err) {
      console.warn('[realtime] Failed to parse server event:', err)
    }
  }

  // k. Store and return
  activeSession = handle
  return handle
}

/**
 * Handle server events from the realtime data channel.
 */
async function handleServerEvent(
  event: ServerEvent,
  handle: RealtimeSessionHandle
): Promise<void> {
  if (event.type === 'response.function_call_arguments.done') {
    if (event.name === 'bookContext') {
      try {
        const args = JSON.parse(event.arguments)
        const { queryText } = args

        // Embed the query -- prefer on-device, fall back to server
        let queryVector: number[]
        if (isEmbeddingReady()) {
          const result = await embedBatch([queryText])
          queryVector = result[0]
        } else {
          const result = await embedTextsOnServer([queryText])
          queryVector = result[0]
        }

        // Search for similar chunks
        const chunks = searchSimilarChunks(handle.bookId, queryVector, 3)
        const context = chunks.map((c: any) => c.text).join('\n\n')

        // Send function call output
        handle.dc.send(
          JSON.stringify({
            type: 'conversation.item.create',
            item: {
              type: 'function_call_output',
              call_id: event.call_id,
              output: context,
            },
          })
        )

        // Trigger response
        handle.dc.send(JSON.stringify({ type: 'response.create' }))
      } catch (err) {
        console.error('[realtime] bookContext tool error:', err)
        handle.onError?.(
          err instanceof Error ? err : new Error('bookContext tool failed')
        )
      }
    } else if (event.name === 'endConversation') {
      closeRealtimeSession()
      handle.onSessionEnded?.()
    }
  } else if (event.type === 'response.audio_transcript.done') {
    // Run guardrail check asynchronously (don't block audio)
    checkGuardrail(event.transcript).then((tripwire) => {
      if (tripwire) {
        handle.onGuardrailTriggered?.()
      }
    })
  } else if (event.type === 'response.audio.delta') {
    handle.onStatusChange?.('speaking')
  } else if (event.type === 'response.audio.done') {
    handle.onStatusChange?.('active')
  } else if (event.type === 'error') {
    handle.onError?.(
      new Error(event.error?.message ?? 'Realtime error')
    )
  }
}

/**
 * Close the active realtime session, stopping all tracks and connections.
 */
export function closeRealtimeSession(): void {
  if (activeSession) {
    // Stop all audio tracks
    activeSession.stream
      .getTracks()
      .forEach((track: any) => track.stop())

    // Close data channel and peer connection
    activeSession.dc.close()
    activeSession.pc.close()

    activeSession = null
  }
}

/**
 * Get the currently active realtime session, if any.
 */
export function getActiveSession(): RealtimeSessionHandle | null {
  return activeSession
}
