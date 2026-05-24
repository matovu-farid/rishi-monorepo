/**
 * React hook around the shared voice-chat service. Replaces the
 * pre-Batch-4 `useRealtimeChat` (ad-hoc useState wrapping the raw
 * react-native-webrtc session) with a thin observer of the
 * shared service's emitters.
 *
 * Mobile readers that need voice chat call:
 *   const { status, chatStatus, start, stop, toggle } = useVoiceChat(bookId)
 *
 * The hook subscribes to onStateChange + onChatStatus and re-renders
 * the consumer when either changes. It also wires
 * `useTtsChatBridge` via its public RealtimeStatus mapping so the TTS
 * player pauses/resumes around chat sessions (G14).
 */
import { useState, useEffect, useCallback, useRef } from 'react'
import type {
  ChatStatus,
  VoiceChatContext,
  VoiceChatPublicState
} from '@rishi/shared/voice-chat'
import { stringToNumberID } from '@rishi/shared/lib/stringToNumberID'
import { getVoiceChatService } from '@/lib/voice-chat/service'
import { getMobileEffectsPort } from '@/lib/voice-chat/sounds'
import type { RealtimeStatus } from '@/lib/realtime/types'

/**
 * CHT-016 — classify an activation error as a mic-permission failure so
 * consumers can show an "Open Settings" CTA on the snackbar/banner.
 * The shared activation pipeline rejects with a message containing
 * "Microphone permission" / "getUserMedia" / "NotAllowedError" when the
 * OS denies the prompt.
 */
function isMicPermissionMessage(msg: string): boolean {
  return /microphone permission|getusermedia|notallowederror|permission denied/i.test(
    msg
  )
}

function friendlyMicPermissionMessage(): string {
  return 'Microphone permission is required for voice chat. Open Settings to enable it.'
}

/**
 * Map the shared `VoiceChatPublicState` + `ChatStatus` to the
 * compatibility `RealtimeStatus` enum existing consumers (and the
 * TTS chat bridge) already use.
 */
function mapToRealtimeStatus(
  publicState: VoiceChatPublicState,
  chatStatus: ChatStatus
): RealtimeStatus {
  if (publicState === 'connecting') return 'connecting'
  if (publicState === 'active') {
    return chatStatus === 'speaking' ? 'speaking' : 'active'
  }
  return 'idle'
}

export interface UseVoiceChatOptions {
  /** Override the page text + outline + paragraph the agent receives. */
  context?: () => VoiceChatContext
  /** Read the user's voice-chat language. */
  getLanguage?: () => string
}

export interface UseVoiceChatResult {
  status: RealtimeStatus
  publicState: VoiceChatPublicState
  chatStatus: ChatStatus
  start: () => Promise<void>
  stop: () => void
  toggle: () => Promise<void>
  isActive: boolean
  /**
   * CHT-016 — Last activation error, surfaced for non-blocking
   * snackbar / banner UI. Null when no error is pending.
   */
  voiceError: string | null
  /** True when `voiceError` is a mic-permission denial — show "Open Settings". */
  isMicPermissionError: boolean
  /** Retry the most recent activation with the same context. */
  retryStart: () => Promise<void>
  /** Clear `voiceError` without re-activating (snackbar dismiss). */
  dismissError: () => void
}

export function useVoiceChat(
  bookId: string,
  opts: UseVoiceChatOptions = {}
): UseVoiceChatResult {
  const svc = getVoiceChatService({ getLanguage: opts.getLanguage })
  const [publicState, setPublicState] = useState<VoiceChatPublicState>(svc.getState())
  const [chatStatus, setChatStatus] = useState<ChatStatus>('idle')
  // CHT-016 — local error state for non-blocking snackbar/banner.
  const [voiceError, setVoiceError] = useState<string | null>(null)
  const [isMicPermissionError, setIsMicPermissionError] = useState(false)
  const contextRef = useRef(opts.context)
  contextRef.current = opts.context

  useEffect(() => {
    svc.start()
    const offState = svc.onStateChange(setPublicState)
    const offChat = svc.onChatStatus(setChatStatus)
    return () => {
      offState()
      offChat()
    }
  }, [svc])

  // CHT-007 — fire the mobile EffectsPort's haptic loop while the model is
  // composing a reply. The shared activation-program already calls
  // `startThinkingSound` on `agent_tool_start`, but the broader
  // `chatStatus === 'thinking'` transition (from `agent_start`) does NOT
  // touch the effects port — so users got no feedback during the most
  // common "model is thinking" window. Mirror it here so any path that
  // lands `chatStatus` on thinking while the service is active drives
  // the haptic loop.
  //
  // The port is a process-wide singleton (see `getMobileEffectsPort`) so
  // we share the interval handle with the service — start/stop are
  // idempotent and won't double-tick.
  useEffect(() => {
    const effects = getMobileEffectsPort()
    if (publicState === 'active' && chatStatus === 'thinking') {
      effects.startThinkingSound()
      return () => {
        effects.stopThinkingSound()
      }
    }
    // Defensive: ensure the loop is stopped on every non-thinking
    // transition so a missed `agent_tool_end` (or any future code path
    // that leaves the loop running) can't strand a recurring haptic.
    effects.stopThinkingSound()
    return undefined
  }, [publicState, chatStatus])

  // CHT-016 — Hold the context that the most recent activation used so
  // `retryStart()` can re-invoke `svc.activate` with the same payload
  // even if the consumer's context provider has changed by the time the
  // user taps "Retry" on the snackbar.
  const lastActivationContextRef = useRef<VoiceChatContext | null>(null)

  const doActivate = useCallback(
    async (ctx: VoiceChatContext) => {
      try {
        const numericBookId = stringToNumberID(bookId)
        lastActivationContextRef.current = ctx
        await svc.activate(numericBookId, ctx)
        // On success, clear any lingering banner from a previous attempt.
        setVoiceError(null)
        setIsMicPermissionError(false)
      } catch (err) {
        const rawMsg =
          err instanceof Error
            ? err.message
            : 'Could not start voice chat. Check your internet connection and try again.'
        const isPerm = isMicPermissionMessage(rawMsg)
        setIsMicPermissionError(isPerm)
        setVoiceError(isPerm ? friendlyMicPermissionMessage() : rawMsg)
      }
    },
    [bookId, svc]
  )

  const start = useCallback(async () => {
    if (
      publicState !== 'idle' &&
      publicState !== 'paused' &&
      publicState !== 'error'
    )
      return
    const ctx = contextRef.current?.() ?? { pageText: '' }
    await doActivate(ctx)
  }, [doActivate, publicState])

  const retryStart = useCallback(async () => {
    // Reuse the context the failed attempt used. Falls back to the live
    // provider (or empty pageText) if no prior activation has run yet.
    const ctx =
      lastActivationContextRef.current ?? contextRef.current?.() ?? { pageText: '' }
    await doActivate(ctx)
  }, [doActivate])

  const dismissError = useCallback(() => {
    setVoiceError(null)
    setIsMicPermissionError(false)
  }, [])

  const stop = useCallback(() => {
    svc.deactivate()
  }, [svc])

  const toggle = useCallback(async () => {
    if (publicState === 'active') {
      stop()
    } else {
      await start()
    }
  }, [publicState, start, stop])

  const status = mapToRealtimeStatus(publicState, chatStatus)

  return {
    status,
    publicState,
    chatStatus,
    start,
    stop,
    toggle,
    isActive: publicState === 'active',
    voiceError,
    isMicPermissionError,
    retryStart,
    dismissError
  }
}

