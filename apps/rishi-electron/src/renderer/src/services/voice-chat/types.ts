import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'

/**
 * Public state surface. Same string union as the internal machine, re-named
 * at the boundary to make the public-vs-internal split visible.
 */
export type VoiceChatPublicState =
  | 'idle'
  | 'connecting'
  | 'active'
  | 'paused'
  | 'offline'
  | 'error'

/** Chat-status surface — finer-grained than VoiceChatPublicState. */
export type ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

export type VoiceErrorReason =
  | 'timeout'
  | 'mic_denied'
  | 'auth_failed'
  | 'connect_failed'
  | 'session_error'
  | 'unknown'

export interface VoiceError {
  reason: VoiceErrorReason
  message?: string
}

export interface VoiceChatContext {
  pageText: string
  outline?: BookOutline
}

export class OfflineError extends Error {
  override readonly name: 'OfflineError' = 'OfflineError'
  constructor() {
    super('You are offline. Voice chat is unavailable until you reconnect.')
  }
}

// --- ports ---

export interface VoiceChatIpc {
  getRealtimeClientSecret(): Promise<string>
}

export interface MediaStreamLike {
  getTracks(): Array<{ stop(): void }>
}

export interface AudioElementLike {
  muted: boolean
  srcObject: unknown
  autoplay: boolean
  pause(): void
}

export interface MediaPort {
  getUserMedia(constraints: MediaStreamConstraints): Promise<MediaStreamLike>
  createAudioElement(): AudioElementLike
}

export interface EffectsPort {
  playReadyChime(): void
  startThinkingSound(): void
  stopThinkingSound(): void
}

export interface ClockPort {
  now(): number
  setTimeout(fn: () => void, ms: number): ReturnType<typeof setTimeout>
  clearTimeout(handle: ReturnType<typeof setTimeout>): void
}

export interface VoiceChatConfig {
  idleTimeoutMs: number
  connectTimeoutMs: number
  keyTtlMs: number
}

// --- session-shape contracts (what the factories must return) ---

export interface RealtimeAgentLike {
  readonly _agent: unknown
}

export interface RealtimeSessionLike {
  connect(opts: { apiKey: string }): Promise<void>
  mute(muted: boolean): void
  interrupt(): void
  close(): void
  updateAgent(agent: RealtimeAgentLike | unknown): Promise<void>
  on(event: string, listener: (...args: unknown[]) => void): void
  off(event: string, listener: (...args: unknown[]) => void): void
}

export interface RtcTransportLike {
  readonly _transport: unknown
}

export interface AgentFactoryArgs {
  bookId: number
  pageText: string
  outline?: BookOutline
  onEndConversation: (reason: string) => void
  rag: RagService
}

export interface WebrtcFactoryArgs {
  mediaStream: MediaStreamLike
  audioElement: AudioElementLike
}

export interface SessionFactoryOpts {
  transport: RtcTransportLike
  apiKey: string
}

export interface VoiceChatServiceDeps {
  rag: RagService
  connectivity: ConnectivityService
  ipc: VoiceChatIpc
  webrtcFactory: (args: WebrtcFactoryArgs) => RtcTransportLike
  agentFactory: (args: AgentFactoryArgs) => RealtimeAgentLike
  sessionFactory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  media: MediaPort
  effects: EffectsPort
  clock: ClockPort
  config: VoiceChatConfig
}

export interface VoiceChatService {
  start(): void
  stop(): void
  activate(bookId: number, ctx: VoiceChatContext): Promise<void>
  preconnect(bookId: number, ctx: VoiceChatContext): Promise<void>
  deactivate(): void
  dispose(): void
  prewarmKey(): void
  getState(): VoiceChatPublicState
  getError(): VoiceError | null
  dismissError(): void
  onStateChange(listener: (state: VoiceChatPublicState) => void): () => void
  onChatStatus(listener: (status: ChatStatus) => void): () => void
  onEndedByAgent(listener: (reason: string) => void): () => void
}
