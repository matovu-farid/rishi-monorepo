/**
 * Spotlight overlay (G28).
 *
 * Mobile equivalent of electron's `SpotlightOverlay.tsx`. Electron
 * draws a semi-opaque SVG with a punched-out rect over the target; on
 * RN we cheat with four `<View>` rectangles arranged around the
 * spotlight — same visual effect, no SVG dependency, plays nicely
 * with Reanimated.
 *
 * The cut-out rect is computed from the target layout in
 * `lib/onboarding/registry`. Padding/corner-radius mirror electron.
 */
import { StyleSheet, View, Dimensions } from 'react-native'
import type { TargetLayout } from '@/lib/onboarding/registry'

interface SpotlightOverlayProps {
  target: TargetLayout
  padding?: number
  borderRadius?: number
}

const DIM = 'rgba(0, 0, 0, 0.5)'

export function SpotlightOverlay({
  target,
  padding = 8,
  borderRadius = 8,
}: SpotlightOverlayProps) {
  const { width: screenW, height: screenH } = Dimensions.get('window')
  const x = Math.max(0, target.x - padding)
  const y = Math.max(0, target.y - padding)
  const w = target.width + padding * 2
  const h = target.height + padding * 2

  return (
    <View
      testID="tour-spotlight"
      pointerEvents="none"
      style={StyleSheet.absoluteFill}
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
    >
      {/* Top dim */}
      <View style={[styles.dim, { left: 0, top: 0, width: screenW, height: y }]} />
      {/* Bottom dim */}
      <View
        style={[
          styles.dim,
          { left: 0, top: y + h, width: screenW, height: Math.max(0, screenH - (y + h)) },
        ]}
      />
      {/* Left dim */}
      <View style={[styles.dim, { left: 0, top: y, width: x, height: h }]} />
      {/* Right dim */}
      <View
        style={[
          styles.dim,
          { left: x + w, top: y, width: Math.max(0, screenW - (x + w)), height: h },
        ]}
      />
      {/* Spotlight border (transparent fill, subtle highlight ring) */}
      <View
        style={[
          styles.ring,
          { left: x, top: y, width: w, height: h, borderRadius },
        ]}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  dim: { position: 'absolute', backgroundColor: DIM },
  ring: {
    position: 'absolute',
    borderColor: 'rgba(255,255,255,0.4)',
    borderWidth: 1,
  },
})
