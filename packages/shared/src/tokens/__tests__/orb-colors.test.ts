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
import {
  ORB_COLORS,
  ORB_DISK_TINTS,
  type AIChatOrbStatus,
} from '../orb-colors'

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

  describe('ORB_DISK_TINTS (WGT-013) — shared disk-tint scale', () => {
    it('exposes an entry for every AIChatOrbStatus key', () => {
      for (const status of ALL_STATUSES) {
        expect(ORB_DISK_TINTS).toHaveProperty(status)
      }
    })

    it('every value is a non-empty rgba()/rgb() string at 0.24 alpha', () => {
      for (const status of ALL_STATUSES) {
        const value = ORB_DISK_TINTS[status]
        expect(typeof value).toBe('string')
        expect(value).toMatch(/^rgba\(/i)
        // The disk tint is the bar color at 0.24 alpha so the disk hue
        // stays in lockstep with the bar hue when ORB_COLORS evolves.
        expect(value).toMatch(/,\s*0\.24\s*\)/)
      }
    })

    it('sentinel disk-tint values match the mobile AIChatOrb source verbatim', () => {
      // Source: apps/mobile/components/chat/AIChatOrb.tsx (pre-WGT-013).
      // Pinning the sentinels prevents drift if a future contributor
      // forgets to update one platform.
      expect(ORB_DISK_TINTS.idle).toBe('rgba(88, 86, 214, 0.24)')
      expect(ORB_DISK_TINTS.connecting).toBe('rgba(59, 130, 246, 0.24)')
      expect(ORB_DISK_TINTS.thinking).toBe('rgba(251, 191, 36, 0.24)')
      expect(ORB_DISK_TINTS.speaking).toBe('rgba(34, 197, 94, 0.24)')
    })

    it('ORB_DISK_TINTS shares the same RGB triplet as ORB_COLORS per status', () => {
      // Extract the first three numeric components — they must match
      // across the two maps because the disk is "the bar color, but
      // dimmer". If a future edit only touches one map this catches it.
      const rgb = (s: string): string => {
        const m = s.match(/rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)/i)
        if (!m) throw new Error(`Unparseable rgba string: ${s}`)
        return `${m[1]},${m[2]},${m[3]}`
      }
      for (const status of ALL_STATUSES) {
        expect(rgb(ORB_DISK_TINTS[status])).toBe(rgb(ORB_COLORS[status]))
      }
    })
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
