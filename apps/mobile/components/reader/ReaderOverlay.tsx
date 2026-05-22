import React, { useCallback, useContext } from 'react'
import { StyleSheet, View } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { AIChatOrb } from '@/components/chat/AIChatOrb'
import { VoiceChatLauncher } from '@/components/chat/VoiceChatLauncher'
import { LockChip } from '@/components/auth/LockChip'
import { MiniPlayer } from '@/components/player/MiniPlayer'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { ReaderShellContext } from '@/components/reader/ReaderShellContext'
import { useAuthStore } from '@/lib/stores/authStore'
import {
  useChatStore,
  type ActivationContext,
} from '@/lib/stores/chatStore'
import { usePlayerStore } from '@/lib/stores/playerStore'
import { zIndex } from '@/lib/theme/tokens'
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
// P1-M / WGT-016 — minimum height of the reader bottom bar (matches the
// Toolbar row floor `minHeight: 44`). The REAL visual height is
// `READER_BOTTOM_BAR_MIN + insets.bottom` because the bottom-variant Toolbar
// pads its own bottom by insets.bottom (≈34pt on notched iPhones). The
// floating widgets must lift by that real height when the bar is visible —
// not the 44pt floor — or they sit underneath the toolbar.
const READER_BOTTOM_BAR_MIN = 44

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
  // P1-M — reflow against the reader's bottom bar so the orb + launcher
  // never overlap the toolbar. MiniPlayer already consumes this; we extend
  // the pattern to the chat orb and voice launcher.
  const shellContext = useContext(ReaderShellContext)
  const bottomBarVisible = shellContext?.bottomBarVisible ?? false
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

  // P1-M — single source of truth for floating-widget bottom offset so the
  // orb, launcher, and the lock-chip overlay stay in lockstep when the
  // reader bottom bar comes and goes.
  // WGT-016 — lift by the bar's REAL height (`min + insets.bottom`) so
  // the widgets clear the toolbar on notched iPhones, not just the
  // visible row floor.
  const floatingBottom =
    insets.bottom +
    FLOATING_BOTTOM_OFFSET +
    (bottomBarVisible ? READER_BOTTOM_BAR_MIN + insets.bottom : 0)

  return (
    <View
      testID={testID ?? 'reader-overlay'}
      pointerEvents="box-none"
      style={StyleSheet.absoluteFill}
    >
      {/*
        WGT-012 — mount the orb whenever the chat lifecycle is live, not
        just when `isChatting` has flipped true. The chatPort can emit a
        non-idle `chatStatus` (e.g. 'connecting' on a remote-resumed
        session) BEFORE the store's `isChatting` follows, and the
        previous `isChatting ? … : null` gate lost that first frame —
        the user briefly saw no orb while the system was already busy.
      */}
      {isChatting || chatStatus !== 'idle' ? (
        <AIChatOrb
          chatStatus={chatStatus}
          onPress={onChatToggle ?? (() => undefined)}
          style={{
            position: 'absolute',
            bottom: floatingBottom,
            left: 32,
            zIndex: zIndex.overlayChrome,
          }}
        />
      ) : null}

      {showVoiceLauncher ? (
        <>
          <VoiceChatLauncher
            isActive={voiceActive}
            onStart={handleVoiceStart}
            onStop={stopConversation}
            style={{
              position: 'absolute',
              bottom: floatingBottom,
              right: 32,
              zIndex: zIndex.overlayChrome,
            }}
          />
          {/*
            P1-T — tiny lock chip overlaid on the launcher's top-right
            corner when the user is signed out. 12pt icon (LockChip
            default), positioned absolutely so the launcher's own
            dimensions don't shift.
          */}
          {!isAuthenticated ? (
            <View
              pointerEvents="none"
              style={{
                position: 'absolute',
                bottom: floatingBottom + 36,
                right: 28,
                zIndex: zIndex.overlayChrome + 1,
              }}
            >
              <LockChip testID="voice-chat-lock-chip" />
            </View>
          ) : null}
        </>
      ) : null}

      {!isChatting && playingState !== 'idle' ? (
        <MiniPlayer bookId={bookId} variant="reader" />
      ) : null}
    </View>
  )
}
