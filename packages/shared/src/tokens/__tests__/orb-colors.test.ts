/**
 * Phase 2 — ORB_COLORS / AIChatOrbStatus contract (shared/tokens).
 *
 * The AIChatOrb status→color map is the single source of truth used by
 * both electron and (Phase 4) mobile to colour the four bars in the orb.
 * The values are transcribed verbatim from the electron component
 * `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx`
 * (lines 30-41) so both platforms render identical hues per state.
 *
 * Anything that drifts here is a behaviour bug — pinning sentinel
 * strings catches accidental edits and silent typos (e.g. `0.7` vs
 * `0.70`, `rgb(` vs `rgba(`).
 */
import { describe, it, expect } from 'vitest'
import { ORB_COLORS, type AIChatOrbStatus } from '../orb-colors'

const ALL_STATUSES: AIChatOrbStatus[] = [
  'idle',
  'connecting',
  'thinking',
  'speaking',
]

describe('ORB_COLORS (shared/tokens)', () => {
  it('exposes an entry for every AIChatOrbStatus key', () => {
    for (const status of ALL_STATUSES) {
      expect(ORB_COLORS).toHaveProperty(status)
    }
  })

  it('every value is a non-empty rgba()/rgb() string', () => {
    for (const status of ALL_STATUSES) {
      const value = ORB_COLORS[status]
      expect(typeof value).toBe('string')
      expect(value.length).toBeGreaterThan(0)
      expect(value).toMatch(/^rgba?\(/i)
    }
  })

  it('sentinel values match the electron AIChatOrb source verbatim', () => {
    // Source: apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx L30-41.
    // Any deviation here means mobile + electron orbs will render different
    // hues for the same state — a parity bug.
    expect(ORB_COLORS.idle).toBe('rgba(88, 86, 214, 0.70)')
    expect(ORB_COLORS.connecting).toBe('rgba(59, 130, 246, 0.80)')
    expect(ORB_COLORS.thinking).toBe('rgba(251, 191, 36, 0.80)')
    expect(ORB_COLORS.speaking).toBe('rgba(34, 197, 94, 0.80)')
  })

  it('AIChatOrbStatus type is exported and structurally complete', () => {
    // Compile-time check: assigning the union literally must succeed for
    // exactly the four documented states. If a key is renamed in the
    // production type, this assignment fails type-check at the tsc step.
    const expected: AIChatOrbStatus[] = [
      'idle',
      'connecting',
      'thinking',
      'speaking',
    ]
    // Runtime: ensure ORB_COLORS does not carry extras beyond the union
    // (catches a `ai-thinking` typo etc.).
    expect(Object.keys(ORB_COLORS).sort()).toEqual([...expected].sort())
  })
})
