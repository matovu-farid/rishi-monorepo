/**
 * Tour tooltip (G28).
 *
 * Mobile parity port of
 * `apps/rishi-electron/.../components/tutorial/TourTooltip.tsx`.
 * Visual style mirrors the electron card: rounded white card,
 * subtle border, title + description + step counter + Skip / Next.
 * Positioning rules (above/below/left/right) are computed relative
 * to the target's layout from the registry.
 */
import { useMemo } from 'react'
import { Text, TouchableOpacity, View, Dimensions, StyleSheet } from 'react-native'
import type { TourStep } from '@/lib/stores/tutorialStore'
import type { TargetLayout } from '@/lib/onboarding/registry'
import { colorsLight } from '@/lib/theme/colors'

interface TourTooltipProps {
  step: TourStep
  stepIndex: number
  totalSteps: number
  target: TargetLayout
  onNext: () => void
  onSkip: () => void
}

const TOOLTIP_WIDTH = 280
const GAP = 12

function computePosition(
  layout: TargetLayout,
  placement: TourStep['position'],
  screen: { width: number; height: number },
): { top: number; left: number } {
  switch (placement) {
    case 'below':
      return {
        top: layout.y + layout.height + GAP,
        left: clampLeft(layout.x + layout.width / 2 - TOOLTIP_WIDTH / 2, screen.width),
      }
    case 'above':
      return {
        // We don't know the rendered tooltip height; assume 140 for the
        // first-paint position (the tooltip will settle once
        // measured). 140 matches the electron card height.
        top: Math.max(GAP, layout.y - 140 - GAP),
        left: clampLeft(layout.x + layout.width / 2 - TOOLTIP_WIDTH / 2, screen.width),
      }
    case 'left':
      return {
        top: Math.max(GAP, layout.y + layout.height / 2 - 70),
        left: Math.max(GAP, layout.x - TOOLTIP_WIDTH - GAP),
      }
    case 'right':
      return {
        top: Math.max(GAP, layout.y + layout.height / 2 - 70),
        left: layout.x + layout.width + GAP,
      }
  }
}

function clampLeft(left: number, screenWidth: number): number {
  return Math.max(GAP, Math.min(left, screenWidth - TOOLTIP_WIDTH - GAP))
}

export function TourTooltip({
  step,
  stepIndex,
  totalSteps,
  target,
  onNext,
  onSkip,
}: TourTooltipProps) {
  const screen = Dimensions.get('window')
  const pos = useMemo(
    () => computePosition(target, step.position, screen),
    [target, step.position, screen],
  )
  const isLast = stepIndex === totalSteps - 1

  return (
    <View
      style={[styles.tooltip, { top: pos.top, left: pos.left, width: TOOLTIP_WIDTH }]}
      accessibilityRole="alert"
    >
      <Text style={styles.title}>{step.title}</Text>
      <Text style={styles.description}>{step.description}</Text>
      <View style={styles.row}>
        <Text style={styles.counter}>
          {stepIndex + 1} of {totalSteps}
        </Text>
        <View style={styles.actions}>
          <TouchableOpacity
            testID="tour-skip"
            onPress={onSkip}
            accessibilityRole="button"
            accessibilityLabel="Skip tutorial"
            style={styles.skipBtn}
          >
            <Text style={styles.skipText}>Skip</Text>
          </TouchableOpacity>
          <TouchableOpacity
            testID="tour-next"
            onPress={onNext}
            accessibilityRole="button"
            accessibilityLabel={isLast ? 'Finish tutorial' : 'Next tutorial step'}
            style={styles.nextBtn}
          >
            <Text style={styles.nextText}>{isLast ? 'Done' : 'Next →'}</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  )
}

// VIS-022 (#82): bind every chrome color to a semantic theme token so
// onboarding cards track the rest of the app palette. Light & dark
// values are folded into the same `colorsLight` reference here; the
// component is read-only at render-time and dark-scheme support can
// flow through a future `useTheme()` upgrade without churning these
// keys again.
const styles = StyleSheet.create({
  tooltip: {
    position: 'absolute',
    backgroundColor: colorsLight.background.primary,
    borderRadius: 12,
    padding: 16,
    shadowColor: '#000',
    shadowOpacity: 0.15,
    shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 },
    elevation: 6,
    borderWidth: 1,
    borderColor: colorsLight.separator.opaque,
  },
  title: {
    fontSize: 14,
    fontWeight: '700',
    color: colorsLight.label.primary,
    marginBottom: 4,
  },
  description: {
    fontSize: 12,
    color: colorsLight.label.secondary,
    lineHeight: 16,
    marginBottom: 12,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  counter: { fontSize: 11, color: colorsLight.label.tertiary },
  actions: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  skipBtn: { paddingHorizontal: 8, paddingVertical: 6 },
  skipText: { fontSize: 12, color: colorsLight.label.tertiary },
  nextBtn: {
    backgroundColor: colorsLight.accent.primary,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 8,
  },
  nextText: { fontSize: 12, color: 'white', fontWeight: '500' },
})
