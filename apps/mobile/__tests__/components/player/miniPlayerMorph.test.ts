/**
 * P1-N — MiniPlayer morph center math.
 *
 * The orb sits at `right: 16` (right-anchored) and expands by translating
 * leftward so the resulting pill lands centered on the visible content
 * width. Naively this is `screenWidth / 2 - 16 - pillWidth / 2`, but on
 * iPad / landscape the safe-area insets are non-zero and the visible
 * content's center is `(screenWidth - insets.left - insets.right) / 2 +
 * insets.left`, NOT `screenWidth / 2`.
 *
 * The miscentered pill was visibly skewed against landscape notches —
 * this test pins the math directly via a pure helper so future regressions
 * surface here instead of at QA review time.
 */

import { computeMiniPlayerTranslateX } from '@/components/player/miniPlayerMorph'

describe('computeMiniPlayerTranslateX (P1-N)', () => {
  it('centers against screen width when insets are zero (portrait phone)', () => {
    // Sanity: with no insets the math collapses back to the original
    // formula so existing portrait behaviour is preserved.
    const tx = computeMiniPlayerTranslateX({
      screenWidth: 390,
      pillWidth: 240,
      rightOffset: 16,
      insets: { left: 0, right: 0 },
    })
    // Visible content center = 195. Pill center sits at right:16 +
    // pillWidth/2 = 16 + 120 = 136 from the right edge → screenWidth - 136
    // = 254 from the left. translateX must move from 254 to 195 → -59.
    expect(tx).toBe(-(390 / 2 - 16 - 240 / 2))
  })

  it('shifts the translate by insets.left so the pill centers in the SAFE area (iPad landscape)', () => {
    // iPad landscape: notch / split-view on the left adds insets.left;
    // home indicator on the right adds insets.right. The visible content
    // center is `(screenWidth - insets.left - insets.right) / 2 +
    // insets.left`, NOT `screenWidth / 2`.
    const tx = computeMiniPlayerTranslateX({
      screenWidth: 1024,
      pillWidth: 240,
      rightOffset: 16,
      insets: { left: 80, right: 40 },
    })
    // Visible center = (1024 - 80 - 40) / 2 + 80 = 452 + 80 = 532.
    // Orb sits at right:16, anchored to the right edge → its left edge
    // is at screenWidth - rightOffset - pillWidth = 1024 - 16 - 240 = 768.
    // Pill center starts at 768 + 120 = 888. translateX must move from
    // 888 to 532 → -356.
    expect(tx).toBe(-356)
  })

  it('returns a non-positive number — the morph never pushes right', () => {
    // The pill always lands left of the orb's anchor point, so a positive
    // translate would indicate the math has gone wrong (e.g. swapped sign).
    const tx = computeMiniPlayerTranslateX({
      screenWidth: 390,
      pillWidth: 240,
      rightOffset: 16,
      insets: { left: 0, right: 0 },
    })
    expect(tx).toBeLessThanOrEqual(0)
  })

  it('asymmetric insets — left-only inset shifts the pill rightward vs symmetric zero', () => {
    // Left-only inset → visible center moves right; translateX should
    // therefore be less negative (closer to 0) than the no-inset case.
    const txZero = computeMiniPlayerTranslateX({
      screenWidth: 1024,
      pillWidth: 240,
      rightOffset: 16,
      insets: { left: 0, right: 0 },
    })
    const txLeft = computeMiniPlayerTranslateX({
      screenWidth: 1024,
      pillWidth: 240,
      rightOffset: 16,
      insets: { left: 100, right: 0 },
    })
    expect(txLeft).toBeGreaterThan(txZero)
  })
})
