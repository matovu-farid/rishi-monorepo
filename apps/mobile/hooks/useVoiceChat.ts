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

