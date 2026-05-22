import { Volume2, MessageSquare, Mic, Sparkles, type LucideIcon } from 'lucide-react'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { FEATURE_COPY } from '@rishi/shared/auth-gating'

export type { PremiumFeature }

export interface PremiumFeatureConfig {
  icon: LucideIcon
  title: string
  description: string
  bullets: string[]
}

export const PREMIUM_FEATURES: Record<PremiumFeature, PremiumFeatureConfig> = {
  tts: {
    icon: Volume2,
    title: FEATURE_COPY.tts.title,
    description: FEATURE_COPY.tts.body,
    bullets: [
      'Natural, expressive voices',
      'Reads EPUB, PDF, and MOBI',
      'Remembers your spot across devices'
    ]
  },
  'ai-chat': {
    icon: MessageSquare,
    title: FEATURE_COPY['ai-chat'].title,
    description: FEATURE_COPY['ai-chat'].body,
    bullets: [
      "Cites passages from the book you're reading",
      'Works across your entire library',
      'Remembers context within a conversation'
    ]
  },
  'voice-chat': {
    icon: Mic,
    title: FEATURE_COPY['voice-chat'].title,
    description: FEATURE_COPY['voice-chat'].body,
    bullets: ['Natural speech recognition', 'Paired with AI book chat']
  },
  'voice-input': {
    icon: Mic,
    title: FEATURE_COPY['voice-input'].title,
    description: FEATURE_COPY['voice-input'].body,
    bullets: ['Natural speech recognition', 'Paired with AI book chat']
  },
  sync: {
    icon: Sparkles,
    title: FEATURE_COPY.sync.title,
    description: FEATURE_COPY.sync.body,
    bullets: []
  },
  'ai-generic': {
    icon: Sparkles,
    title: FEATURE_COPY['ai-generic'].title,
    description: FEATURE_COPY['ai-generic'].body,
    bullets: []
  }
}
