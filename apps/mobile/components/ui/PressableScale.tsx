import React from 'react'
import { Pressable, type ViewStyle } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
} from 'react-native-reanimated'
import { useTheme } from '@/lib/theme'

export type PressableScaleProps = {
  children: React.ReactNode
  onPress: () => void
  onLongPress?: () => void
  onPressIn?: () => void
  onPressOut?: () => void
  hitSlop?:
    | number
    | { top: number; bottom: number; left: number; right: number }
  scale?: number
  disabled?: boolean
  accessibilityLabel: string
  accessibilityRole?: 'button' | 'link' | 'imagebutton' | 'menuitem'
  accessibilityHint?: string
  style?: ViewStyle
  testID?: string
}

export function PressableScale({
  children,
  onPress,
  onLongPress,
  onPressIn,
  onPressOut,
  hitSlop,
  scale = 0.95,
  disabled = false,
  accessibilityLabel,
  accessibilityRole = 'button',
  accessibilityHint,
  style,
  testID,
}: PressableScaleProps): React.JSX.Element {
  const { motion, reduceMotion } = useTheme()
  const scaleValue = useSharedValue(1)
  const opacityValue = useSharedValue(1)

  const animatedStyle = useAnimatedStyle(() => {
    if (reduceMotion) {
      return { opacity: opacityValue.value }
    }
    return { transform: [{ scale: scaleValue.value }] }
  })

  const handlePressIn = () => {
    if (disabled) return
    if (reduceMotion) {
      opacityValue.value = withTiming(0.7, { duration: motion.duration.fast })
    } else {
      scaleValue.value = withSpring(scale, motion.spring.snappy)
    }
    onPressIn?.()
  }

  const handlePressOut = () => {
    if (disabled) return
    if (reduceMotion) {
      opacityValue.value = withTiming(1, { duration: motion.duration.fast })
    } else {
      scaleValue.value = withSpring(1, motion.spring.snappy)
    }
    onPressOut?.()
  }

  const handlePress = () => {
    if (disabled) return
    onPress()
  }

  const handleLongPress = onLongPress
    ? () => {
        if (disabled) return
        onLongPress()
      }
    : undefined

  return (
    // UI-SPEC §7c: do not pass `disabled` to Pressable so VoiceOver still
    // announces the element with `accessibilityState={{ disabled }}` ("dimmed").
    // Press is no-op'd via the early-returns in handlePress* above.
    <Pressable
      onPress={handlePress}
      onLongPress={handleLongPress}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      hitSlop={hitSlop}
      accessibilityRole={accessibilityRole}
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
      accessibilityState={{ disabled }}
      testID={testID}
    >
      <Animated.View style={[style, animatedStyle, disabled ? { opacity: 0.4 } : null]}>
        {children}
      </Animated.View>
    </Pressable>
  )
}
