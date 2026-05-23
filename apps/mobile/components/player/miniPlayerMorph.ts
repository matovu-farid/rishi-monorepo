/**
 * P1-N — MiniPlayer morph helpers.
 *
 * The orb collapses to `right: rightOffset` and expands by translating
 * leftward so the resulting pill is centered in the visible content
 * width (i.e. the safe area, not the raw screen). On iPad / landscape
 * `insets.left` and `insets.right` are non-zero, so the visible center is
 * `(screenWidth - insets.left - insets.right) / 2 + insets.left`, NOT
 * `screenWidth / 2`.
 *
 * Pure module — no React, no Reanimated state. The `'worklet'` directive
 * on `computeMiniPlayerTranslateX` makes it callable from inside a
 * Reanimated worklet (e.g. `useAnimatedStyle`); the function itself is
 * still importable from JS for tests.
 */

export interface MiniPlayerMorphArgs {
  /** Total screen width, in points (from `useWindowDimensions().width`). */
  screenWidth: number
  /** Expanded pill width, in points. */
  pillWidth: number
  /** Right anchor of the orb / wrapper, in points (typically `16`). */
  rightOffset: number
  /** Safe-area insets along the horizontal axis. */
  insets: { left: number; right: number }
}

/**
 * Returns the translateX (always ≤ 0) the morph must apply when the pill
 * is fully expanded so its center lands on the visible-area center.
 *
 *   visibleCenter = (screenWidth - insets.left - insets.right) / 2 +
 *                    insets.left
 *   pillCenterAtRest = screenWidth - rightOffset - pillWidth / 2
 *   translateX = visibleCenter - pillCenterAtRest
 */
export function computeMiniPlayerTranslateX({
  screenWidth,
  pillWidth,
  rightOffset,
  insets,
}: MiniPlayerMorphArgs): number {
  'worklet'
  const visibleCenter =
    (screenWidth - insets.left - insets.right) / 2 + insets.left
  const pillCenterAtRest = screenWidth - rightOffset - pillWidth / 2
  return visibleCenter - pillCenterAtRest
}
