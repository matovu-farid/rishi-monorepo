// AIChatOrb status → color map. Shared by electron (source of truth) and
// mobile Phase 4. Values transcribed verbatim from
// apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx L30-41.

export type AIChatOrbStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'

export const ORB_COLORS: Record<AIChatOrbStatus, string> = {
  idle: 'rgba(88, 86, 214, 0.70)',
  connecting: 'rgba(59, 130, 246, 0.80)',
  thinking: 'rgba(251, 191, 36, 0.80)',
  speaking: 'rgba(34, 197, 94, 0.80)',
}
