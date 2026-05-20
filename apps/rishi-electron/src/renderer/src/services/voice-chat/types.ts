import type { BookOutline } from '@/lib/api'
import type { RagService } from '@/services/rag'
import type { ConnectivityService } from '@/services/connectivity'
import type { VisualSummary } from '@/lib/visualHeuristic'
import type { CaptureResult } from '@/modules/pageCapture'

/**
 * Public state surface. Same string union as the internal machine, re-named
 * at the boundary to make the public-vs-internal split visible.
 */
export type VoiceChatPublicState = 'idle' | 'connecting' | 'active' | 'paused' | 'offline' | 'error'

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
  /** The paragraph TTS was on at chat-start, so the model can resolve "this", "what you just read", etc. */
  activeParagraphText?: string
  /** Counts of visual content (equations/figures/images) on the user's current page. */
  visualSummary?: VisualSummary
}

export class OfflineError extends Error {
  override readonly name = 'OfflineError' as const
  constructor() {
    super('You are offline. Voice chat is unavailable until you reconnect.')
  }
}

// --- ports ---

export interface VoiceChatIpc {
  getRealtimeClientSecret(language: string): Promise<string>
  /**
   * STT for audio buffered during the connect window. Required even though
   * the buffered-replay feature can be disabled — keeping it required forces
   * future test doubles to acknowledge it exists, avoiding silent regressions
   * when callers assume it's wired.
   */
  transcribeAudio(blob: Blob): Promise<string>
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

/**
 * Narrow shape the activation pipeline needs from the platform's
 * MediaRecorder. Matches the WHATWG API but lets us mock it in tests.
 */
export interface MediaRecorderLike {
  start(timesliceMs?: number): void
  stop(): void
  readonly state: 'inactive' | 'recording' | 'paused'
  ondataavailable: ((event: { data: Blob }) => void) | null
  onstop: (() => void) | null
}

export interface MediaPort {
  getUserMedia(constraints: MediaStreamConstraints): Promise<MediaStreamLike>
  createAudioElement(): AudioElementLike
  /**
   * Construct a recorder bound to the given mic stream. Returns null if the
   * platform lacks MediaRecorder support (older Electron, unsupported codec).
   * Optional so legacy deps still type-check; the activation pipeline guards.
   */
  createMediaRecorder?(stream: MediaStreamLike): MediaRecorderLike | null
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

export interface LocalVadConfig {
  /** RMS threshold in [0,1]. Speech detected when smoothed RMS exceeds this. */
  rmsThreshold: number
  /** ms of sub-threshold audio before end-of-utterance is declared. */
  hangoverMs: number
  /** Polling interval for the AnalyserNode. */
  pollIntervalMs: number
  /** FFT size for the AnalyserNode (smallest valid power-of-2 is 32). */
  fftSize: number
}

export interface ServerVadConfig {
  /** Maps to config.audio.input.turnDetection.threshold on the OpenAI Realtime session. */
  threshold: number
  silenceDurationMs?: number
  prefixPaddingMs?: number
}

export interface VoiceChatConfig {
  /**
   * Auto-close the realtime session after this many ms with no agent activity
   * (no audio_start/audio_stopped/agent_start/agent_end/tool events). Prevents
   * a user who leaves voice chat on and walks away from incurring open-ended
   * audio + transcription token billing.
   */
  inactivityTimeoutMs: number
  connectTimeoutMs: number
  keyTtlMs: number
  /**
   * When true, the activation pipeline records mic audio during the connect
   * window and replays it as a text message once the session is live. When
   * false (or undefined), the recorder is never started — useful as a kill
   * switch if the feature misbehaves in production.
   */
  bufferedSpeechReplayEnabled?: boolean
  /** Local energy-based VAD knobs. Required so wiring sites are explicit. */
  localVad: LocalVadConfig
  /** Server-side turn_detection knobs. Required so wiring sites are explicit. */
  serverVad: ServerVadConfig
}

/**
 * Local Voice Activity Detector. Listens to a MediaStream via the Web Audio
 * AnalyserNode + smoothed RMS, and exposes a Promise gate the activation
 * pipeline awaits before draining the buffered-speech recorder.
 */
export interface LocalVoiceVad {
  /**
   * True if smoothed RMS has crossed `rmsThreshold` at least once since
   * construction. Sticky for the instance's lifetime — dispose + reconstruct
   * to reset.
   */
  everSpoke(): boolean
  /**
   * Resolves when VAD observes a silence-hangover period after speech, OR
   * immediately if `everSpoke()` is false (nothing to wait for), OR
   * immediately if already past the hangover.
   * Rejects with `VadTimeoutError` if `timeoutMs` elapses first.
   * Rejects with `VadDisposedError` if `dispose()` is called while waiting.
   */
  waitForSpeechEnd(timeoutMs: number): Promise<void>
  /** Stop polling, close the AudioContext. Idempotent. */
  dispose(): void
}

export interface VadPort {
  /**
   * Construct a VAD attached to the given stream. Returns `null` when
   * `AudioContext` is unavailable or its construction fails — the activation
   * pipeline treats `null` as VAD-disabled and proceeds without gating.
   */
  create(stream: MediaStreamLike): LocalVoiceVad | null
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
  updateAgent(agent: unknown): Promise<void>
  /**
   * Inject a text user message into the live session (creates a
   * conversation.item and triggers a response). Used to replay speech the
   * user uttered during the connect window.
   */
  sendMessage(message: string): void
  /**
   * Append an image to the conversation history. The SDK's `addImage`
   * delegates to `transport.addImage` which emits a `conversation.item.create`
   * carrying an `input_image` content part. Pass `triggerResponse: false`
   * to keep this a pure history append.
   */
  addImage(image: string, opts?: { triggerResponse?: boolean }): void
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
  activeParagraphText?: string
  onEndConversation: (reason: string) => void
  /**
   * Forward captured page screenshots into the live realtime session.
   * Wired by activation-program.ts after the session is created.
   */
  onInspectImage?: (image: CaptureResult) => void
  /**
   * Counts of visual content on the user's page. When defined, the agent
   * gains an `inspectCurrentPage` tool and a `Visual context` instructions
   * section. Undefined = vision feature disabled.
   */
  visualSummary?: { equations: number; figures: number; images: number }
  rag: RagService
  /** ISO-639-1 code for the language the agent must respond in. */
  language: string
}

export interface WebrtcFactoryArgs {
  mediaStream: MediaStreamLike
  audioElement: AudioElementLike
}

export interface SessionFactoryOpts {
  transport: RtcTransportLike
  apiKey: string
  /**
   * Server-side turn-detection config. The factory translates this to the
   * OpenAI Realtime SDK's `config.audio.input.turnDetection` shape so SDK
   * types don't leak into the public service contract.
   */
  serverVad: ServerVadConfig
}

export interface VoiceChatServiceDeps {
  rag: RagService
  connectivity: ConnectivityService
  ipc: VoiceChatIpc
  webrtcFactory: (args: WebrtcFactoryArgs) => RtcTransportLike
  agentFactory: (args: AgentFactoryArgs) => RealtimeAgentLike
  sessionFactory: (agent: RealtimeAgentLike, opts: SessionFactoryOpts) => RealtimeSessionLike
  media: MediaPort
  vad: VadPort
  effects: EffectsPort
  clock: ClockPort
  config: VoiceChatConfig
  /**
   * Read the user's chosen voice-chat language at activation time. Synchronous
   * because the value lives in a hydrated Zustand store. Returns an ISO-639-1
   * code; callers must accept any string and validate downstream.
   */
  getLanguage(): string
}

export interface VoiceChatService {
  start(): void
  stop(): void
  activate(bookId: number, ctx: VoiceChatContext): Promise<void>
  preconnect(bookId: number, ctx: VoiceChatContext): Promise<void>
  deactivate(): void
  dispose(): void
  prewarmKey(): void
  /**
   * Drop the cached realtime ephemeral key. Call after changing a setting
   * (e.g., language) that's baked into the minted key — the next activate()
   * will refetch with the new value.
   */
  invalidateKey(): void
  getState(): VoiceChatPublicState
  getError(): VoiceError | null
  dismissError(): void
  onStateChange(listener: (state: VoiceChatPublicState) => void): () => void
  onChatStatus(listener: (status: ChatStatus) => void): () => void
  onEndedByAgent(listener: (reason: string) => void): () => void
}
