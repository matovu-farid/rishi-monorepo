import { describe, it, expect } from 'vitest'
import { PREMIUM_FEATURES, type PremiumFeature } from './features'

describe('Premium Features Config', () => {
  it('should define TTS feature with required fields', () => {
    const tts = PREMIUM_FEATURES.tts
    expect(tts).toBeDefined()
    expect(tts.title).toBe('Listen to your books')
    expect(tts.description).toBeTruthy()
    expect(tts.bullets).toBeInstanceOf(Array)
    expect(tts.bullets.length).toBeGreaterThan(0)
    expect(tts.icon).toBeDefined()
  })

  it('should define chat feature with required fields', () => {
    const chat = PREMIUM_FEATURES.chat
    expect(chat).toBeDefined()
    expect(chat.title).toBe('Chat with your books')
    expect(chat.description).toBeTruthy()
    expect(chat.bullets).toBeInstanceOf(Array)
    expect(chat.bullets.length).toBeGreaterThan(0)
  })

  it('should define voice-input feature with required fields', () => {
    const voice = PREMIUM_FEATURES['voice-input']
    expect(voice).toBeDefined()
    expect(voice.title).toBe('Talk to your books')
    expect(voice.description).toBeTruthy()
    expect(voice.bullets).toBeInstanceOf(Array)
    expect(voice.bullets.length).toBeGreaterThan(0)
  })

  it('should define ai-generic feature as a fallback', () => {
    const generic = PREMIUM_FEATURES['ai-generic']
    expect(generic).toBeDefined()
    expect(generic.title).toBeTruthy()
    expect(generic.bullets).toEqual([])
  })

  it('should have all expected feature keys', () => {
    const keys = Object.keys(PREMIUM_FEATURES) as PremiumFeature[]
    expect(keys).toContain('tts')
    expect(keys).toContain('chat')
    expect(keys).toContain('voice-input')
    expect(keys).toContain('ai-generic')
    expect(keys.length).toBe(4)
  })

  it('should have icon property for each feature', () => {
    for (const [, config] of Object.entries(PREMIUM_FEATURES)) {
      expect(config.icon).toBeDefined()
      // Lucide icons are either function components or ForwardRef objects
      expect(typeof config.icon === 'function' || typeof config.icon === 'object').toBe(true)
    }
  })

  it('should have non-empty title and description for each feature', () => {
    for (const [, config] of Object.entries(PREMIUM_FEATURES)) {
      expect(config.title).toBeTruthy()
      expect(config.description).toBeTruthy()
    }
  })

  it('should have specific bullet text for TTS feature', () => {
    const tts = PREMIUM_FEATURES.tts
    expect(tts.bullets).toContain('Natural, expressive voices')
    expect(tts.bullets).toContain('Reads EPUB, PDF, MOBI, and DjVu')
    expect(tts.bullets).toContain('Remembers your spot across devices')
  })

  it('should have specific bullet text for chat feature', () => {
    const chat = PREMIUM_FEATURES.chat
    expect(chat.bullets).toContain("Cites passages from the book you're reading")
    expect(chat.bullets).toContain('Works across your entire library')
    expect(chat.bullets).toContain('Remembers context within a conversation')
  })

  it('should have specific bullet text for voice-input feature', () => {
    const voice = PREMIUM_FEATURES['voice-input']
    expect(voice.bullets).toContain('Natural speech recognition')
    expect(voice.bullets).toContain('Paired with AI book chat')
  })

  it('should have empty bullets for ai-generic feature', () => {
    expect(PREMIUM_FEATURES['ai-generic'].bullets).toHaveLength(0)
  })

  it('should have correct descriptions', () => {
    expect(PREMIUM_FEATURES.tts.description).toContain('text-to-speech')
    expect(PREMIUM_FEATURES.chat.description).toContain('Ask questions')
    expect(PREMIUM_FEATURES['voice-input'].description).toContain('hands-free')
    expect(PREMIUM_FEATURES['ai-generic'].description).toContain('Sign in')
  })

  it('each feature config should match PremiumFeatureConfig shape', () => {
    for (const [, config] of Object.entries(PREMIUM_FEATURES)) {
      expect(typeof config.title).toBe('string')
      expect(typeof config.description).toBe('string')
      expect(Array.isArray(config.bullets)).toBe(true)
      expect(config.icon).toBeDefined()
    }
  })
})
