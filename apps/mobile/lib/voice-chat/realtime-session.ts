/**
 * Mobile implementation of the WebRTC transport + RealtimeAgent +
 * RealtimeSession contracts the shared voice-chat service expects.
 *
 * Electron uses the `@openai/agents/realtime` SDK which abstracts WebRTC
 * + data-channel framing + tool dispatch. That SDK isn't React-Native
 * compatible (depends on Web globals + Browser EventTarget). So this
 * module reimplements the slice the shared service needs against
 * `react-native-webrtc` and raw data-channel JSON.
 *
 * Slice scope:
 *   - `connect({ apiKey })` performs the standard OpenAI SDP exchange.
 *   - `on/off` event names map: 'agent_start', 'audio_start',
 *     'audio_stopped', 'agent_end', 'agent_tool_start', 'agent_tool_end',
 *     'error'.
 *   - `sendMessage(text)` issues conversation.item.create + response.create.
 *   - `addImage(dataUrl, { triggerResponse })` issues conversation.item.create
 *     with an input_image content part.
 *   - `mute(muted)` flips the cloned-track `enabled` flag via
 *     pc.getSenders().
 *   - `updateAgent(newAgent)` sends `session.update` with the new
 *     instructions + tools list.
 *
 * Tool dispatch on mobile:
 *   - bookContext: handled here against the injected RAG port.
 *   - endConversation: invokes `onEndConversation` (provided to the
 *     agent factory).
 *   - inspectCurrentPage: calls captureCurrentPage() and emits the
 *     image into the session as a conversation item.
 */
import { RTCPeerConnection, mediaDevices } from 'react-native-webrtc'
import type {
  AgentFactoryArgs,
  MediaStreamLike,
  RealtimeAgentLike,
  RealtimeSessionLike,
  RtcTransportLike,
  SessionFactoryOpts,
  VoiceChatRagPort,
  WebrtcFactoryArgs
} from '@rishi/shared/voice-chat'
import {
  BOOK_CONTEXT_TOOL_SPEC,
  END_CONVERSATION_TOOL_SPEC,
  INSPECT_CURRENT_PAGE_TOOL_SPEC,
  renderRealtimeInstructions
} from '@rishi/shared/voice-chat/build-realtime-agent'
import { captureCurrentPage } from './page-capture'

const OPENAI_REALTIME_URL = 'https://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview'

// ─── Transport ──────────────────────────────────────────────────────────────

interface MobileRtcTransport extends RtcTransportLike {
  readonly _transport: {
    pc: RTCPeerConnection
    dc: RTCDataChannel
    sendStream: MediaStreamLike
  }
}

type RTCDataChannel = ReturnType<RTCPeerConnection['createDataChannel']>

/**
 * Construct a peer connection + data channel + bound mic stream.
 * The send stream is added to the PC immediately so SDP carries the
 * track; the shared service is responsible for keeping the cloned
 * tracks `.enabled = false` until VAD/buffered-speech replay completes.
 */
export const mobileWebrtcFactory = (args: WebrtcFactoryArgs): MobileRtcTransport => {
  const pc = new RTCPeerConnection({})
  const dc = pc.createDataChannel('oai-events')

  // Add cloned (hard-muted) tracks to the PC. The track + stream types
  // here are react-native-webrtc's narrower variants; we work through
  // `unknown` so the WHATWG-shaped MediaStreamLike port doesn't have to
  // know about the platform-specific class.
  const tracks = args.mediaStream.getTracks() as unknown as Array<{
    stop(): void
    enabled?: boolean
  }>
  const stream = args.mediaStream as unknown as Parameters<typeof pc.addTrack>[1]
  for (const t of tracks) {
    // Best-effort: react-native-webrtc tracks expose `enabled` like the WHATWG API.
    try {
      ;(t as { enabled: boolean }).enabled = false
    } catch {
      /* ignore */
    }
    pc.addTrack(t as unknown as Parameters<typeof pc.addTrack>[0], stream)
  }

  return {
    _transport: { pc, dc, sendStream: args.mediaStream }
  }
}

// ─── Agent ──────────────────────────────────────────────────────────────────

interface MobileAgent extends RealtimeAgentLike {
  readonly _agent: {
    instructions: string
    tools: Array<typeof BOOK_CONTEXT_TOOL_SPEC | typeof END_CONVERSATION_TOOL_SPEC | typeof INSPECT_CURRENT_PAGE_TOOL_SPEC>
    onEndConversation: (reason: string) => void
    onInspectImage?: (image: { dataUrl: string; width: number; height: number; bytes: number }) => void
    rag: VoiceChatRagPort
    bookId: number
  }
}

/** Cast a mobile agent back to its concrete shape (used by the session factory). */
function asMobileAgent(agent: RealtimeAgentLike): MobileAgent {
  return agent as MobileAgent
}

export const mobileAgentFactory = (args: AgentFactoryArgs): MobileAgent => {
  const instructions = renderRealtimeInstructions({
    pageText: args.pageText,
    language: args.language,
    outline: args.outline,
    activeParagraphText: args.activeParagraphText,
    visualSummary: args.visualSummary
  })

  const tools: MobileAgent['_agent']['tools'] = [
    BOOK_CONTEXT_TOOL_SPEC,
    END_CONVERSATION_TOOL_SPEC
  ]
  if (args.visualSummary !== undefined) {
    tools.push(INSPECT_CURRENT_PAGE_TOOL_SPEC)
  }

  return {
    _agent: {
      instructions,
      tools,
      onEndConversation: args.onEndConversation,
      onInspectImage: args.onInspectImage,
      rag: args.rag,
      bookId: args.bookId
    }
  }
}

// ─── Session ────────────────────────────────────────────────────────────────

type Listener = (...args: unknown[]) => void

interface InternalSession extends RealtimeSessionLike {
  /** Internal: replace the live agent's instructions/tools via session.update. */
}

/**
 * Build a session bound to the given agent + transport. The session is
 * NOT connected until `connect()` is called — this is the shared
 * activation pipeline's contract.
 */
export const mobileSessionFactory = (
  agent: RealtimeAgentLike,
  opts: SessionFactoryOpts
): InternalSession => {
  const a = asMobileAgent(agent)
  const transport = (opts.transport as MobileRtcTransport)._transport
  const { pc, dc } = transport

  const listeners = new Map<string, Set<Listener>>()
  function emit(ev: string, ...payload: unknown[]): void {
    const set = listeners.get(ev)
    if (!set) return
    for (const l of [...set]) {
      try {
        l(...payload)
      } catch {
        /* listener errors must not break the session */
      }
    }
  }

  let currentAgent = a._agent
  let isConnected = false

  function send(message: unknown): void {
    if (!isConnected) return
    try {
      dc.send(JSON.stringify(message))
    } catch (err) {
      emit('error', err)
    }
  }

  function buildSessionUpdate(): unknown {
    return {
      type: 'session.update',
      session: {
        instructions: currentAgent.instructions,
        tools: currentAgent.tools.map((t) => ({
          type: 'function' as const,
          name: t.name,
          description: t.description,
          parameters: t.parameters
        })),
        turn_detection: {
          type: 'server_vad' as const,
          threshold: opts.serverVad.threshold,
          silence_duration_ms: opts.serverVad.silenceDurationMs ?? 700,
          prefix_padding_ms: opts.serverVad.prefixPaddingMs ?? 300
        }
      }
    }
  }

  async function handleToolCall(name: string, callId: string, argsJson: string): Promise<void> {
    emit('agent_tool_start')
    let output = ''
    try {
      if (name === 'bookContext') {
        const parsed = JSON.parse(argsJson) as { queryText?: string }
        const queryText = parsed.queryText ?? ''
        const chunks = await currentAgent.rag.searchSemantic(queryText, currentAgent.bookId, 3)
        output = chunks.map((c) => c.text).join('\n\n') || 'No relevant chunks were found.'
      } else if (name === 'endConversation') {
        const parsed = JSON.parse(argsJson) as { reason?: string }
        const reason = parsed.reason ?? 'unspecified'
        // Fire the callback before we report to the model. Service will
        // emit endedByAgent which triggers chat-bridge → CHAT_ENDED.
        currentAgent.onEndConversation(reason)
        output = 'OK.'
      } else if (name === 'inspectCurrentPage') {
        const parsed = JSON.parse(argsJson) as { detail?: 'low' | 'high' }
        const detail = parsed.detail ?? 'low'
        const image = await captureCurrentPage({ detail })
        currentAgent.onInspectImage?.(image)
        output = `Page image captured at ${image.width}x${image.height} (${detail} detail). Attached to the conversation.`
      } else {
        output = `Unknown tool: ${name}`
      }
    } catch (err) {
      output = err instanceof Error ? err.message : String(err)
      emit('error', err)
    }
    send({
      type: 'conversation.item.create',
      item: {
        type: 'function_call_output' as const,
        call_id: callId,
        output
      }
    })
    send({ type: 'response.create' })
    emit('agent_tool_end')
  }

  ;(dc as unknown as { onopen: (() => void) | null }).onopen = (): void => {
    isConnected = true
    send(buildSessionUpdate())
  }

  ;(dc as unknown as { onmessage: ((event: { data: string }) => void) | null }).onmessage = (
    event: { data: string }
  ): void => {
    try {
      const msg = JSON.parse(event.data) as Record<string, unknown>
      const type = msg.type as string | undefined
      switch (type) {
        case 'response.created':
          emit('agent_start')
          break
        case 'response.audio.delta':
        case 'response.output_audio.delta':
          emit('audio_start')
          break
        case 'response.audio.done':
        case 'response.output_audio.done':
          emit('audio_stopped')
          break
        case 'response.done':
          emit('agent_end')
          break
        case 'response.function_call_arguments.done':
          void handleToolCall(
            String(msg.name),
            String(msg.call_id),
            String((msg as { arguments?: string }).arguments ?? '{}')
          )
          break
        case 'error':
          emit('error', new Error(String((msg as { error?: { message?: string } }).error?.message ?? 'realtime error')))
          break
        default:
          break
      }
    } catch (err) {
      emit('error', err)
    }
  }

  return {
    async connect({ apiKey }) {
      const offer = await pc.createOffer({})
      await pc.setLocalDescription(offer)

      const sdpResponse = await fetch(OPENAI_REALTIME_URL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/sdp'
        },
        body: offer.sdp ?? ''
      })

      if (!sdpResponse.ok) {
        throw new Error(`Realtime SDP exchange failed: ${sdpResponse.status}`)
      }

      const answerSdp = await sdpResponse.text()
      // react-native-webrtc's RTCSessionDescriptionInit requires sdp to be
      // a non-optional string. SDP responses are always strings; assert.
      await pc.setRemoteDescription({
        type: 'answer' as const,
        sdp: answerSdp
      } as unknown as Parameters<typeof pc.setRemoteDescription>[0])
    },

    mute(muted) {
      // Flip the enabled bit on the cloned tracks. react-native-webrtc
      // exposes `enabled` directly on each sender's track.
      try {
        const senders = pc.getSenders()
        for (const s of senders) {
          const track = (s as unknown as { track?: { enabled: boolean } }).track
          if (track) track.enabled = !muted
        }
      } catch {
        /* best-effort */
      }
    },

    interrupt() {
      // Sending response.cancel asks the server to stop generating.
      send({ type: 'response.cancel' })
    },

    close() {
      try {
        dc.close()
      } catch {
        /* ignore */
      }
      try {
        pc.close()
      } catch {
        /* ignore */
      }
      isConnected = false
      listeners.clear()
    },

    async updateAgent(newAgent) {
      const next = asMobileAgent(newAgent as RealtimeAgentLike)
      currentAgent = next._agent
      send(buildSessionUpdate())
    },

    sendMessage(message) {
      send({
        type: 'conversation.item.create',
        item: {
          type: 'message' as const,
          role: 'user' as const,
          content: [{ type: 'input_text' as const, text: message }]
        }
      })
      send({ type: 'response.create' })
    },

    addImage(image, addImageOpts) {
      send({
        type: 'conversation.item.create',
        item: {
          type: 'message' as const,
          role: 'user' as const,
          content: [{ type: 'input_image' as const, image_url: image }]
        }
      })
      if (addImageOpts?.triggerResponse) {
        send({ type: 'response.create' })
      }
    },

    on(event, listener) {
      if (!listeners.has(event)) listeners.set(event, new Set())
      listeners.get(event)!.add(listener)
    },

    off(event, listener) {
      listeners.get(event)?.delete(listener)
    }
  }
}
