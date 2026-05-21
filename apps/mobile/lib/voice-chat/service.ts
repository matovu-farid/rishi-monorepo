/**
 * Mobile voice-chat service factory. Wires the shared
 * `createVoiceChatService` against the mobile-specific ports:
 *   - MediaPort: react-native-webrtc.
 *   - VadPort: shared `createLocalVad` (returns null on RN because
 *     there's no global AudioContext; activation pipeline degrades
 *     gracefully). See BATCH-4-NOTES.md.
 *   - EphemeralKeyPort + transcribeAudio IPC: apiClient against the
 *     worker.
 *   - EmitterPort/EffectsPort: expo-audio chime + no-op thinking sound
 *     (see sounds.ts).
 *   - ConnectivityPort: `createMobileConnectivityPort()`.
 *   - AgentBuilderPort: mobile agent factory wrapping the shared
 *     `renderRealtimeInstructions`, with the `inspectCurrentPage` tool
 *     wired to `react-native-view-shot` via `page-capture.ts`.
 *
 * The service is a singleton — voice chat is a single-active-session
 * resource (one mic, one realtime connection), so a global instance
 * matches the actual hardware affordance.
 */
import {
  createVoiceChatService,
  createLocalVad,
  type VoiceChatService,
  type VoiceChatConfig,
  type VadPort
} from '@rishi/shared/voice-chat'
import { createMobileConnectivityPort } from '@/lib/connectivity/MobileConnectivityPort'
import { mobileMediaPort } from './media-port'
import { mobileVoiceChatIpc } from './ipc'
import { mobileWebrtcFactory, mobileAgentFactory, mobileSessionFactory } from './realtime-session'
import { createMobileEffectsPort } from './sounds'
import { createMobileRagPort } from './rag-port'

const DEFAULT_CONFIG: VoiceChatConfig = {
  inactivityTimeoutMs: 3 * 60 * 1000,
  connectTimeoutMs: 60 * 1000,
  keyTtlMs: 9 * 60 * 1000,
  // No MediaRecorder on RN — the activation pipeline branches on
  // `media.createMediaRecorder` being undefined, so this flag is moot
  // on mobile. Leaving it true to keep the contract uniform.
  bufferedSpeechReplayEnabled: true,
  localVad: {
    rmsThreshold: 0.05,
    hangoverMs: 700,
    pollIntervalMs: 50,
    fftSize: 256
  },
  serverVad: {
    threshold: 0.7,
    silenceDurationMs: 700,
    prefixPaddingMs: 300
  }
}

/**
 * Shared `createLocalVad` reads global AudioContext, which is absent on
 * RN. The port simply returns null in that case, so the activation
 * pipeline skips the VAD gate entirely. If a future batch upgrades
 * `react-native-worklets` past 0.6 we can swap in
 * `react-native-audio-api`'s AudioContext polyfill via a global stub —
 * the shared `createLocalVad` will then start returning real instances.
 */
const mobileVadPort: VadPort = {
  create: (stream) => createLocalVad(stream, DEFAULT_CONFIG.localVad)
}

let _service: VoiceChatService | null = null

export interface BuildOpts {
  /** Read the user's chosen language (e.g. from prefsStore). */
  getLanguage?: () => string
  /** Override config knobs. */
  config?: Partial<VoiceChatConfig>
}

/**
 * Construct (or return the existing) voice-chat service.
 * Idempotent.
 */
export function getVoiceChatService(opts: BuildOpts = {}): VoiceChatService {
  if (_service) return _service

  _service = createVoiceChatService({
    rag: createMobileRagPort(),
    connectivity: createMobileConnectivityPort(),
    ipc: mobileVoiceChatIpc,
    webrtcFactory: mobileWebrtcFactory,
    agentFactory: mobileAgentFactory,
    sessionFactory: mobileSessionFactory,
    media: mobileMediaPort,
    vad: mobileVadPort,
    effects: createMobileEffectsPort(),
    clock: {
      now: () => Date.now(),
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: (h) => clearTimeout(h)
    },
    network: {
      preconnectOpenAI: () => {
        // No-op on RN — there's no <link rel="preconnect"> equivalent.
        // The TLS handshake will be paid on the first activate() call.
      }
    },
    config: { ...DEFAULT_CONFIG, ...opts.config },
    getLanguage: opts.getLanguage ?? (() => 'en')
  })

  return _service
}

/** Internal: reset for tests. */
export function _resetVoiceChatServiceForTests(): void {
  if (_service) {
    try {
      _service.dispose()
    } catch {
      /* ignore */
    }
  }
  _service = null
}
