import type React from 'react'
import { useChatStore } from '@/stores/chatStore'
import TTSControls from '@/components/tts/TTSControls'
import AIChatOrb from '@/components/chat/AIChatOrb'
import VoiceChatLauncher from '@/components/chat/VoiceChatLauncher'
import { TTSVisualCue } from './TTSVisualCue'
import { isSharingEnabledForUser } from '@/lib/sharing-flag'
import { SessionEntryButton } from '@/components/sharing/SessionEntryButton'
import { useAuthStore } from '@/stores/authStore'

type ReaderOverlayControlsProps = {
  bookId: string
  chatPanelOpen: boolean
  onChatOrbClick: () => void
}

/**
 * Bundle the three floating overlay widgets every reader view renders:
 *  - the AI chat orb (only when a chat session is active),
 *  - the voice chat launcher,
 *  - the TTS controls (visually hidden while chatting so audio cleanup
 *    doesn't tear down between toggles).
 *
 * Chat state is read internally from the store so the parent view doesn't
 * have to subscribe and pass it down.
 *
 * `chatPanelOpen` is accepted as a prop for symmetry with the view-level
 * state machine, even though it's not currently rendered here — keeping the
 * surface stable so future affordances (e.g. an "open chat panel" affordance
 * on the orb) can be added without changing the call sites.
 */
export default function ReaderOverlayControls({
  bookId,
  chatPanelOpen: _chatPanelOpen,
  onChatOrbClick
}: ReaderOverlayControlsProps): React.JSX.Element {
  void _chatPanelOpen
  const isChatting = useChatStore((s) => s.isChatting)
  const chatStatus = useChatStore((s) => s.chatStatus)
  const userId = useAuthStore((s) => s.user?.id)
  // No userId → user is unauthenticated; hide the sharing entry button rather
  // than leak the affordance to a user who can't actually start a session.
  const showSharingEntry = userId !== undefined && isSharingEnabledForUser(userId)

  return (
    <>
      {isChatting ? <AIChatOrb chatStatus={chatStatus} onClick={onChatOrbClick} /> : null}
      <VoiceChatLauncher />
      {showSharingEntry ? <SessionEntryButton bookId={Number(bookId)} /> : null}
      <div style={{ display: isChatting ? 'none' : 'contents' }}>
        <TTSControls bookId={bookId} />
        <TTSVisualCue />
      </div>
    </>
  )
}
