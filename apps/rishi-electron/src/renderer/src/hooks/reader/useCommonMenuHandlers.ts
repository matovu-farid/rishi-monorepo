import { useMemo, useRef, useEffect } from 'react'
import { usePlayerStore } from '@/stores/playerStore'
import { useChatStore } from '@/stores/chatStore'
import type { MenuCommandHandlers } from '@/hooks/useMenuCommands'

type RequireAuth = (feature: string, action: () => void) => void
type Updater = (updater: (prev: boolean) => boolean) => void

export type CommonMenuHandlers = Pick<
  MenuCommandHandlers,
  'toggleTOC' | 'readAloudToggle' | 'openChat' | 'voiceChat'
>

/**
 * The four menu handlers every reader view shares verbatim:
 *  - `toggleTOC` — flip the TOC sheet open/closed
 *  - `readAloudToggle` — pause/resume TTS or kick off a fresh play (gated by
 *    auth)
 *  - `openChat` — toggle the chat panel (gated by auth)
 *  - `voiceChat` — toggle voice chat (gated by auth when turning on)
 *
 * Caller-supplied callbacks (`requireAuth`, `setChatPanelOpen`, `setTocOpen`)
 * are stored in refs so the returned handlers stay referentially stable
 * across re-renders — `useMenuCommands` re-subscribes on identity changes
 * and that would otherwise churn every render.
 */
export function useCommonMenuHandlers({
  requireAuth,
  setChatPanelOpen,
  setTocOpen
}: {
  requireAuth: RequireAuth
  setChatPanelOpen: Updater
  setTocOpen: Updater
}): CommonMenuHandlers {
  const requireAuthRef = useRef(requireAuth)
  const setChatPanelOpenRef = useRef(setChatPanelOpen)
  const setTocOpenRef = useRef(setTocOpen)

  // Keep the refs current without invalidating the memoized handlers.
  useEffect(() => {
    requireAuthRef.current = requireAuth
  }, [requireAuth])
  useEffect(() => {
    setChatPanelOpenRef.current = setChatPanelOpen
  }, [setChatPanelOpen])
  useEffect(() => {
    setTocOpenRef.current = setTocOpen
  }, [setTocOpen])

  return useMemo<CommonMenuHandlers>(
    () => ({
      toggleTOC: () => setTocOpenRef.current((v) => !v),
      readAloudToggle: () => {
        const send = usePlayerStore.getState().send
        if (!send) return
        const state = usePlayerStore.getState().playingState
        if (state === 'playing') send({ type: 'PAUSE' })
        else if (state.startsWith('paused')) send({ type: 'RESUME' })
        else requireAuthRef.current('tts', () => send({ type: 'PLAY' }))
      },
      openChat: () => requireAuthRef.current('chat', () => setChatPanelOpenRef.current((v) => !v)),
      voiceChat: () => {
        const { isChatting: chatting, setIsChatting } = useChatStore.getState()
        if (chatting) setIsChatting(false)
        else requireAuthRef.current('voice-input', () => setIsChatting(true))
      }
    }),
    []
  )
}
