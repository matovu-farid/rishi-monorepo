import React from 'react'
import { ContextualHint } from '@/components/tutorial/ContextualHint'
import type { ChatStatus } from '@/stores/chatStore'

interface AIChatOrbProps {
  chatStatus: ChatStatus
  onClick: () => void
}

const barHeights = [8, 14, 20, 12]

const glassContainer: React.CSSProperties = {
  background:
    'linear-gradient(135deg, rgba(255,255,255,0.30) 0%, rgba(255,255,255,0.12) 40%, rgba(200,210,230,0.16) 100%)',
  backdropFilter: 'blur(40px) saturate(180%)',
  WebkitBackdropFilter: 'blur(40px) saturate(180%)',
  border: '1px solid rgba(255,255,255,0.45)',
  boxShadow:
    '0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12), inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)'
}

function getBarColor(status: ChatStatus): string {
  switch (status) {
    case 'connecting':
      return 'rgba(59, 130, 246, 0.80)' // blue
    case 'thinking':
      return 'rgba(251, 191, 36, 0.80)' // amber
    case 'speaking':
      return 'rgba(34, 197, 94, 0.80)' // green
    default:
      return 'rgba(88, 86, 214, 0.70)' // purple (idle)
  }
}

export default function AIChatOrb({ chatStatus, onClick }: AIChatOrbProps) {
  const isAnimating = chatStatus !== 'idle'
  const isConnecting = chatStatus === 'connecting'
  const barColor = getBarColor(chatStatus)

  function getBarAnimation(index: number): string {
    if (isConnecting) {
      return `ai-connecting 1.4s ease-in-out ${index * 0.15}s infinite`
    }
    if (!isAnimating) return 'none'
    if (chatStatus === 'thinking') {
      return `ai-pulse 1.6s ease-in-out ${index * 0.2}s infinite`
    }
    return `ai-waveform 1.2s ease-in-out ${index * 0.15}s infinite`
  }

  return (
    <ContextualHint
      id="ai-chat-orb"
      title="AI Chat"
      description="Tap to ask questions about this book. AI answers using the book's content."
      dotPosition="top-left"
    >
      <style>{`
        @keyframes ai-waveform {
          0%, 100% { transform: scaleY(0.4); }
          50% { transform: scaleY(1); }
        }
        @keyframes ai-pulse {
          0%, 100% { opacity: 0.5; transform: scaleY(0.6); }
          50% { opacity: 1; transform: scaleY(1); }
        }
        @keyframes ai-connecting {
          0%, 100% { transform: scaleY(0.3); opacity: 0.5; }
          50% { transform: scaleY(1); opacity: 1; }
        }
        @keyframes ai-pulse-ring {
          0% { transform: translate(-50%, -50%) scale(0.9); opacity: 0.7; }
          50% { transform: translate(-50%, -50%) scale(1.15); opacity: 0.3; }
          100% { transform: translate(-50%, -50%) scale(0.9); opacity: 0.7; }
        }
        @media (prefers-reduced-motion: reduce) {
          @keyframes ai-waveform {
            0%, 50%, 100% { transform: scaleY(0.7); }
          }
          @keyframes ai-pulse {
            0%, 50%, 100% { opacity: 0.75; transform: scaleY(0.8); }
          }
          @keyframes ai-connecting {
            0%, 50%, 100% { transform: scaleY(0.6); opacity: 0.75; }
          }
          @keyframes ai-pulse-ring {
            0%, 50%, 100% { transform: translate(-50%, -50%) scale(1); opacity: 0.5; }
          }
        }
      `}</style>

      <div
        data-tour="ai-chat"
        onClick={onClick}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            onClick()
          }
        }}
        role="button"
        tabIndex={0}
        aria-label={isConnecting ? 'AI chat connecting' : 'Toggle AI chat'}
        className="fixed z-50 flex items-center justify-center cursor-pointer"
        style={{
          ...glassContainer,
          top: '50%',
          left: '50%',
          transform: 'translate(-50%, -50%)',
          width: 52,
          height: 52,
          borderRadius: '50%'
        }}
      >
        {/* Pulsing ring shown while connecting */}
        {isConnecting && (
          <div
            style={{
              position: 'absolute',
              top: '50%',
              left: '50%',
              width: 56,
              height: 56,
              borderRadius: '50%',
              border: '2px solid rgba(59, 130, 246, 0.6)',
              animation: 'ai-pulse-ring 1.4s ease-in-out infinite',
              pointerEvents: 'none'
            }}
          />
        )}
        <div className="flex items-center gap-[3px]">
          {barHeights.map((h, i) => (
            <div
              key={i}
              style={{
                width: 3,
                height: h,
                borderRadius: 1.5,
                backgroundColor: barColor,
                transformOrigin: 'center',
                animation: getBarAnimation(i)
              }}
            />
          ))}
        </div>
      </div>
    </ContextualHint>
  )
}
