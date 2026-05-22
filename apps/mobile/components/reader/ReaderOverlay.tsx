import React, { useCallback } from 'react'
import { StyleSheet, View } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { AIChatOrb } from '@/components/chat/AIChatOrb'
import { VoiceChatLauncher } from '@/components/chat/VoiceChatLauncher'
import { MiniPlayer } from '@/components/player/MiniPlayer'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { useAuthStore } from '@/lib/stores/authStore'
import {
  useChatStore,
  type ActivationContext,
} from '@/lib/stores/chatStore'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { stringToNumberID } from '@rishi/shared/lib/stringToNumberID'

export interface ReaderOverlayProps {
  bookId?: string
  onChatToggle?: () => void
  /**
   * Lazy provider for the voice-chat activation context (P0-O). Per-format
   * readers wire this with whatever subset they can compute — chapter
   * label as `pageText`, the spine outline, the active TTS paragraph,
   * etc. Called once per launcher tap so the latest reader state is
   * captured at activation time.
   */
  getActivationContext?: () => ActivationContext
  testID?: string
}

const FLOATING_BOTTOM_OFFSET = 112

/**
 * Pure orchestrator. Reads (isChatting, voiceState, playingState) and
 * mounts the floating widgets per UI-SPEC §9.4. No business logic of its
 * own — all state lives in chatStore / playerStore.
 */
export function ReaderOverlay({
  bookId,
  onChatToggle,
  getActivationContext,
  testID,
}: ReaderOverlayProps): React.JSX.Element {
  const insets = useSafeAreaInsets()
  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const voiceState = useChatStore((s) => s.voiceState)
  const startChat = useChatStore((s) => s.startChat)
  const stopConversation = useChatStore((s) => s.stopConversation)
  const playingState = usePlayerStore((s) => s.playingState)

  const requireVoiceChat = useRequireAuth('voice-chat')

  // P1-R: hide the launcher once the user has explicitly dismissed the
  // gate for voice-chat. Signed-in users always see the control.
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const voiceChatDismissed = useAuthStore((s) =>
    s.dismissedFeatures.has('voice-chat'),
  )
  const showVoiceLauncher = isAuthenticated || !voiceChatDismissed

  const voiceActive =
    voiceState === 'connecting' ||
    voiceState === 'listening' ||
    voiceState === 'thinking' ||
    voiceState === 'speaking'

  const handleVoiceStart = useCallback(() => {
    requireVoiceChat(() => {
      if (bookId) {
        // Gather reader state lazily so we capture the latest page /
        // paragraph at activation time (P0-O). When no provider is wired
        // (e.g. tests, headless screens), pass `undefined` and let
        // chatStore fall back to an empty context.
        const ctx = getActivationContext?.()
        startChat(stringToNumberID(bookId), ctx)
      }
    })
  }, [requireVoiceChat, startChat, bookId, getActivationContext])

  return (
    <View
      testID={testID ?? 'reader-overlay'}
      pointerEvents="box-none"
      style={StyleSheet.absoluteFill}
    >
      {isChatting ? (
        <AIChatOrb
          chatStatus={chatStatus}
          onPress={onChatToggle ?? (() => undefined)}
          style={{
            position: 'absolute',
            bottom: insets.bottom + FLOATING_BOTTOM_OFFSET,
            left: 32,
            zIndex: 20,
          }}
        />
      ) : null}

      {showVoiceLauncher ? (
        <VoiceChatLauncher
          isActive={voiceActive}
          onStart={handleVoiceStart}
          onStop={stopConversation}
          style={{
            position: 'absolute',
            bottom: insets.bottom + FLOATING_BOTTOM_OFFSET,
            right: 32,
            zIndex: 20,
          }}
        />
      ) : null}

      {!isChatting && playingState !== 'idle' ? (
        <MiniPlayer bookId={bookId} variant="reader" />
      ) : null}
    </View>
  )
}
