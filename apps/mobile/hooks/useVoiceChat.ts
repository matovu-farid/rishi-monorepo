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
import { Alert } from 'react-native'
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
}

export function useVoiceChat(
  bookId: string,
  opts: UseVoiceChatOptions = {}
): UseVoiceChatResult {
  const svc = getVoiceChatService({ getLanguage: opts.getLanguage })
  const [publicState, setPublicState] = useState<VoiceChatPublicState>(svc.getState())
  const [chatStatus, setChatStatus] = useState<ChatStatus>('idle')
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

  const start = useCallback(async () => {
    if (publicState !== 'idle' && publicState !== 'paused' && publicState !== 'error') return
    const ctx = contextRef.current?.() ?? { pageText: '' }
    try {
      // The shared service expects a numeric bookId. Hash strings to a
      // stable number to match the rest of the mobile pipeline.
      const numericBookId = stringToNumberID(bookId)
      await svc.activate(numericBookId, ctx)
    } catch (err) {
      Alert.alert(
        'Voice Chat Error',
        err instanceof Error
          ? err.message
          : 'Could not start voice chat. Check your internet connection and try again.'
      )
    }
  }, [bookId, publicState, svc])

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
    isActive: publicState === 'active'
  }
}

