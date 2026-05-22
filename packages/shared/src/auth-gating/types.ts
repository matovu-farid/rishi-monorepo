export type PremiumFeature =
  | 'tts'
  | 'ai-chat'
  | 'voice-chat'
  | 'voice-input'
  | 'sync'
  | 'ai-generic'

export interface FeatureCopy {
  title: string
  body: string
  cta: string
}
