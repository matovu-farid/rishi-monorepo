import type React from 'react'
import { Mic, MicOff } from 'lucide-react'
import { useChatStore } from '@/stores/chatStore'
import { useRequireAuth } from '@/hooks/useRequireAuth'
import { ContextualHint } from '@/components/tutorial/ContextualHint'

const glassContainer: React.CSSProperties = {
  background:
    'linear-gradient(135deg, rgba(255,255,255,0.30) 0%, rgba(255,255,255,0.12) 40%, rgba(200,210,230,0.16) 100%)',
  backdropFilter: 'blur(40px) saturate(180%)',
  WebkitBackdropFilter: 'blur(40px) saturate(180%)',
  border: '1px solid rgba(255,255,255,0.45)',
  boxShadow:
    '0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12), inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)'
}

/**
 * Floating launcher for voice chat. Pairs visually with the TTS play orb —
 * sits directly above it in the bottom-right corner so both "talk to the
 * book" affordances are thumb-reachable.
 */
export default function VoiceChatLauncher() {
  const isChatting = useChatStore((s) => s.isChatting)
  const setIsChatting = useChatStore((s) => s.setIsChatting)
  const { requireAuth, AuthDialog } = useRequireAuth()

  const handleClick = () => {
    if (isChatting) {
      setIsChatting(false)
    } else {
      requireAuth('voice-input', () => setIsChatting(true))
    }
  }

  const Icon = isChatting ? MicOff : Mic

  return (
    <>
      <ContextualHint
        id="voice-chat-launcher"
        title="Voice chat"
        description="Tap to talk with the AI about this book. It listens and responds out loud."
        dotPosition="top-left"
      >
        <button
          onClick={handleClick}
          aria-label={isChatting ? 'Stop voice chat' : 'Start voice chat'}
          className="fixed z-50 flex items-center justify-center cursor-pointer transition-transform duration-150 hover:scale-105 active:scale-95"
          style={{
            ...glassContainer,
            bottom: 96,
            right: 32,
            width: 52,
            height: 52,
            borderRadius: '50%'
          }}
        >
          <Icon size={20} className="text-black/60" />
        </button>
      </ContextualHint>
      {AuthDialog}
    </>
  )
}
