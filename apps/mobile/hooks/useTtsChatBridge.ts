/**
 * Bridges voice-chat status changes to the player state machine so the
 * TTS player can pause-and-resume around a voice-chat session. This is
 * a thin observer — it does NOT own the chat session itself.
 *
 * The shared playerMachine handles the position preservation logic:
 *   - CHAT_STARTED from playing/loading/waitingForParagraphs transitions
 *     to paused.clean with wantsAutoResumeAfterChat=true. paragraphIndex
 *     is preserved.
 *   - CHAT_ENDED restores the same paragraphIndex via loading. If the
 *     user wasn't listening when chat started, the event is a no-op.
 *
 * Usage:
 *   const realtimeStatus = useRealtimeChat(bookId).status
 *   useTtsChatBridge(realtimeStatus)
 *
 * The bridge does NOT need to know about expo-audio or the TTS service
 * directly — the player machine is the single source of truth.
 */
import { useEffect, useRef } from 'react'
import { usePlayerStore } from '@/lib/stores/playerStore'
import type { RealtimeStatus } from '@/lib/realtime/types'

/**
 * Watch the voice-chat status. When it enters an "active" state
 * (connecting OR active OR speaking), dispatch CHAT_STARTED. When it
 * returns to idle or ending, dispatch CHAT_ENDED.
 *
 * Idempotent — re-dispatching the same event is harmless because the
 * machine's per-state CHAT_STARTED/CHAT_ENDED handlers are no-ops for
 * states where the event has no effect.
 */
export function useTtsChatBridge(status: RealtimeStatus): void {
  const send = usePlayerStore((s) => s.send)
  const lastDispatched = useRef<'started' | 'ended' | null>(null)

  useEffect(() => {
    if (!send) return

    const inChat =
      status === 'connecting' || status === 'active' || status === 'speaking'

    if (inChat && lastDispatched.current !== 'started') {
      send({ type: 'CHAT_STARTED' })
      lastDispatched.current = 'started'
    } else if (!inChat && lastDispatched.current === 'started') {
      send({ type: 'CHAT_ENDED' })
      lastDispatched.current = 'ended'
    }
  }, [status, send])
}
