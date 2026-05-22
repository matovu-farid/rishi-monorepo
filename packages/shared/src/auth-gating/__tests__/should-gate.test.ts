/**
 * Phase 1 — shouldGate pure predicate.
 *
 * The gate is the single source of truth for "should this signed-out user
 * see the premium feature sheet". Behaviour is intentionally trivial in
 * v1: gate iff user is null. The feature parameter is reserved for
 * future per-feature plans (subscription tier, entitlements) and MUST
 * not influence the result today.
 *
 * This file lives in shared so both electron and mobile call the same
 * predicate — no behavioural drift.
 */
import { describe, it, expect } from 'vitest'
import { shouldGate } from '../shouldGate'
import type { PremiumFeature } from '../types'

const ALL_FEATURES: PremiumFeature[] = [
  'tts',
  'ai-chat',
  'voice-chat',
  'voice-input',
  'sync',
  'ai-generic',
]

describe('shouldGate (shared/auth-gating)', () => {
  it('returns true for every PremiumFeature when user is null', () => {
    for (const feature of ALL_FEATURES) {
      expect(shouldGate(null, feature)).toBe(true)
    }
  })

  it('returns false for every PremiumFeature when user has an id', () => {
    const user = { id: 'user-123' }
    for (const feature of ALL_FEATURES) {
      expect(shouldGate(user, feature)).toBe(false)
    }
  })

  it('result is independent of which feature is passed (v1 contract)', () => {
    // Pin the invariant that a signed-out result is uniform across features.
    const nullResults = ALL_FEATURES.map((f) => shouldGate(null, f))
    expect(new Set(nullResults).size).toBe(1)

    // Same for signed-in: every feature returns the same false.
    const user = { id: 'u' }
    const signedResults = ALL_FEATURES.map((f) => shouldGate(user, f))
    expect(new Set(signedResults).size).toBe(1)
  })

  it('does not throw for any valid (user, feature) combination', () => {
    for (const feature of ALL_FEATURES) {
      expect(() => shouldGate(null, feature)).not.toThrow()
      expect(() => shouldGate({ id: 'x' }, feature)).not.toThrow()
    }
  })
})
