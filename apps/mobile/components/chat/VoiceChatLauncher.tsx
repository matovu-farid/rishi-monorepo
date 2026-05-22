import React, { useEffect } from 'react'
import { Pressable, StyleSheet, View, type ViewStyle } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'
import Animated, {
  Easing,
  cancelAnimation,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withSequence,
  withSpring,
  withTiming,
} from 'react-native-reanimated'

import { GlassDisk } from '@/components/ui/GlassDisk'
import { useTheme } from '@/lib/theme'

export interface VoiceChatLauncherProps {
  isActive: boolean
  onStart: () => void
  onStop: () => void
  style?: ViewStyle
  testID?: string
}

const ORB_SIZE = 52

export function VoiceChatLauncher({
  isActive,
  onStart,
  onStop,
  style,
  testID,
}: VoiceChatLauncherProps): React.JSX.Element {
  const { colors, motion, reduceMotion } = useTheme()
  const breathScale = useSharedValue(1)

  useEffect(() => {
    cancelAnimation(breathScale)
    if (isActive || reduceMotion) {
      breathScale.value = withSpring(1, motion.spring.snappy)
      return
    }
    breathScale.value = withRepeat(
      withSequence(
        withTiming(1, {
          duration: 1000,
          easing: Easing.inOut(Easing.quad),
        }),
        withTiming(1.04, {
          duration: 1000,
          easing: Easing.inOut(Easing.quad),
        }),
      ),
      -1,
      true,
    )
  }, [isActive, reduceMotion, breathScale, motion.spring.snappy])

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: breathScale.value }],
  }))

  const handlePress = () => {
    if (!reduceMotion) {
      void Haptics.selectionAsync()
    }
    if (isActive) {
      onStop()
    } else {
      onStart()
    }
  }

  return (
    <Pressable
      testID={testID ?? 'voice-chat-launcher'}
      onPress={handlePress}
      accessibilityRole="button"
      accessibilityLabel={isActive ? 'Stop voice chat' : 'Start voice chat'}
      accessibilityHint={
        isActive
          ? 'End the voice conversation'
          : 'Begin a real-time voice conversation about this book'
      }
      hitSlop={4}
      style={style}
    >
      <Animated.View style={animatedStyle}>
        <GlassDisk size={ORB_SIZE}>
          <View
            style={{
              ...StyleSheet.absoluteFillObject,
              alignItems: 'center',
              justifyContent: 'center',
            }}
            pointerEvents="none"
            accessible={false}
          >
            <Ionicons
              name={isActive ? 'mic-off-outline' : 'mic-outline'}
              size={22}
              color={colors.label.primary}
              style={{ opacity: 0.6 }}
            />
          </View>
        </GlassDisk>
      </Animated.View>
    </Pressable>
  )
}
