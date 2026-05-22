import type { PremiumFeature, FeatureCopy } from './types'

/**
 * GAT-015: each body reads as a value proposition (what the user
 * gets), not a restatement of the title's "Sign in to …" verb. The
 * title already commits the action; the body should describe the
 * unlocked experience.
 */
export const FEATURE_COPY: Record<PremiumFeature, FeatureCopy> = {
  tts: {
    title: 'Sign in to listen',
    body: 'Hear your books read aloud in expressive voices.',
    cta: 'Sign in',
  },
  'voice-chat': {
    title: 'Sign in to talk',
    body: 'Ask questions out loud and hear answers back.',
    cta: 'Sign in',
  },
  'voice-input': {
    title: 'Sign in to dictate',
    body: 'Dictate your questions instead of typing.',
    cta: 'Sign in',
  },
  'ai-chat': {
    title: 'Sign in to ask',
    body: "Chat about what you're reading and get cited answers.",
    cta: 'Sign in',
  },
  sync: {
    title: 'Sign in to sync',
    body: 'Keep your library, highlights, and progress across devices.',
    cta: 'Sign in',
  },
  'ai-generic': {
    title: 'Sign in to continue',
    body: "Unlock Rishi's reading tools.",
    cta: 'Sign in',
  },
}
