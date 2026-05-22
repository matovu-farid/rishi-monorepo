import React from 'react'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'
import { useTheme } from '@/lib/theme'
import { PressableScale } from './PressableScale'

export type HapticVariant = 'selection' | 'soft' | 'light' | 'medium'

export type IconButtonProps = {
  name: keyof typeof Ionicons.glyphMap
  onPress: () => void
  /**
   * Optional long-press handler. Fires a `medium` haptic by default
   * (independent of the short-press haptic). Used e.g. for the reader
   * Back chevron's pin-toggle (P1-E).
   */
  onLongPress?: () => void
  size?: number
  color?: string
  label: string
  hitSlop?:
    | number
    | { top: number; bottom: number; left: number; right: number }
  haptic?: HapticVariant
  disabled?: boolean
  testID?: string
}

// 22pt icon + 11pt hitSlop per side = 44pt minimum touch target per UI-SPEC §10.3.
const DEFAULT_HIT_SLOP = { top: 11, bottom: 11, left: 11, right: 11 }

function fireHaptic(variant: HapticVariant): void {
  switch (variant) {
    case 'selection':
      void Haptics.selectionAsync()
      return
    case 'soft':
      void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)
      return
    case 'light':
      void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light)
      return
    case 'medium':
      void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
      return
  }
}

export function IconButton({
  name,
  onPress,
  onLongPress,
  size = 22,
  color,
  label,
  hitSlop = DEFAULT_HIT_SLOP,
  haptic = 'selection',
  disabled = false,
  testID,
}: IconButtonProps): React.JSX.Element {
  const { colors } = useTheme()
  const effectiveColor = disabled
    ? colors.label.quaternary
    : color ?? colors.label.primary

  const handlePress = () => {
    if (disabled) return
    fireHaptic(haptic)
    onPress()
  }

  // Long-press fires a stronger (`medium`) haptic so the gesture is
  // perceptibly different from a tap. Caller still drives behaviour.
  const handleLongPress = onLongPress
    ? () => {
        if (disabled) return
        fireHaptic('medium')
        onLongPress()
      }
    : undefined

  return (
    <PressableScale
      onPress={handlePress}
      onLongPress={handleLongPress}
      accessibilityLabel={label}
      disabled={disabled}
      hitSlop={hitSlop}
      testID={testID}
    >
      <Ionicons name={name} size={size} color={effectiveColor} />
    </PressableScale>
  )
}
