import { describe, it, expect } from 'vitest'
import { Z_INDEX } from './zIndex'

describe('Z_INDEX scale (#202 / VIS-009)', () => {
  it('keeps STICKY page chrome below the modal layer', () => {
    expect(Z_INDEX.STICKY).toBeLessThan(Z_INDEX.MODAL)
  })

  it('caps MENU at or below MODAL so a Modal opened later wins', () => {
    // Regression guard: the bug was Menu at 9999, which trumped every modal
    // in the app. MENU must never exceed MODAL.
    expect(Z_INDEX.MENU).toBeLessThanOrEqual(Z_INDEX.MODAL)
  })

  it('places OVERLAY above the MODAL layer', () => {
    expect(Z_INDEX.OVERLAY).toBeGreaterThan(Z_INDEX.MODAL)
  })

  it('places TOAST at the top of the stacking scale', () => {
    expect(Z_INDEX.TOAST).toBeGreaterThan(Z_INDEX.OVERLAY)
    expect(Z_INDEX.TOAST).toBeGreaterThan(Z_INDEX.MODAL)
  })

  it('never re-introduces the old z-9999 overflow', () => {
    for (const v of Object.values(Z_INDEX)) {
      expect(v).toBeLessThan(9999)
    }
  })
})
