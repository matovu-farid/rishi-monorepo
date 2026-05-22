import React, { useEffect, useRef } from 'react'
import {
  AccessibilityInfo,
  Pressable,
  StyleSheet,
  View,
  type ViewStyle,
} from 'react-native'
import * as Haptics from 'expo-haptics'
import Animated, {
  Easing,
  cancelAnimation,
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withRepeat,
  withSequence,
  withTiming,
} from 'react-native-reanimated'

import { GlassDisk } from '@/components/ui/GlassDisk'
import { useTheme } from '@/lib/theme'
import {
  ORB_COLORS,
  ORB_DISK_TINTS,
  type AIChatOrbStatus,
} from '@rishi/shared/tokens/orb-colors'

export interface AIChatOrbProps {
  chatStatus: AIChatOrbStatus
  onPress: () => void
  style?: ViewStyle
  testID?: string
}

// WGT-013 — disk tint comes from the shared scale so electron + mobile cannot
// drift. The previous local `ORB_TINTS` constant has been removed.

const A11Y_LABELS: Record<AIChatOrbStatus, string> = {
  idle: 'AI chat',
  connecting: 'AI chat — connecting',
  thinking: 'AI chat — thinking',
  speaking: 'AI chat — speaking',
}

const BAR_HEIGHTS = [8, 14, 20, 12] as const
const ORB_SIZE = 52
const RING_SIZE = 56

export function AIChatOrb({
  chatStatus,
  onPress,
  style,
  testID,
}: AIChatOrbProps): React.JSX.Element {
  const { reduceMotion } = useTheme()

  const bar0Scale = useSharedValue(1)
  const bar1Scale = useSharedValue(1)
  const bar2Scale = useSharedValue(1)
  const bar3Scale = useSharedValue(1)
  const ringScale = useSharedValue(0.9)
  const ringOpacity = useSharedValue(0)

  // Announce status changes for screen-reader users. We track the
  // previously-rendered status so that the initial mount does NOT
  // announce — only true transitions trigger an announcement. This
  // pairs with `accessibilityValue={{ text }}` on the Pressable so
  // VoiceOver/TalkBack re-read the orb's state when focus persists
  // across a status change. (P1-P)
  const prevStatusRef = useRef<AIChatOrbStatus | null>(null)
  useEffect(() => {
    const prev = prevStatusRef.current
    if (prev !== null && prev !== chatStatus) {
      AccessibilityInfo.announceForAccessibility(A11Y_LABELS[chatStatus])
    }
    prevStatusRef.current = chatStatus
  }, [chatStatus])

  useEffect(() => {
    const bars = [bar0Scale, bar1Scale, bar2Scale, bar3Scale]
    bars.forEach((b) => cancelAnimation(b))
    cancelAnimation(ringScale)
    cancelAnimation(ringOpacity)

    if (chatStatus === 'idle' || reduceMotion) {
      const restValue = reduceMotion ? 0.7 : 1
      bars.forEach((b) => {
        b.value = withTiming(restValue, { duration: 150 })
      })
      ringOpacity.value = withTiming(0, { duration: 150 })
      return
    }

    if (chatStatus === 'speaking') {
      const halfPeriod = 300
      const stagger = 150
      bars.forEach((b, i) => {
        b.value = withDelay(
          i * stagger,
          withRepeat(
            withSequence(
              withTiming(0.4, { duration: halfPeriod }),
              withTiming(1, { duration: halfPeriod }),
            ),
            -1,
            true,
          ),
        )
      })
      ringOpacity.value = withTiming(0, { duration: 150 })
      return
    }

    if (chatStatus === 'thinking') {
      const halfPeriod = 400
      const stagger = 200
      bars.forEach((b, i) => {
        b.value = withDelay(
          i * stagger,
          withRepeat(
            withSequence(
              withTiming(0.6, { duration: halfPeriod }),
              withTiming(1, { duration: halfPeriod }),
            ),
            -1,
            true,
          ),
        )
      })
      ringOpacity.value = withTiming(0, { duration: 150 })
      return
    }

    // connecting
    const halfPeriod = 350
    const stagger = 150
    bars.forEach((b, i) => {
      b.value = withDelay(
        i * stagger,
        withRepeat(
          withSequence(
            withTiming(0.4, { duration: halfPeriod }),
            withTiming(1, { duration: halfPeriod }),
          ),
          -1,
          true,
        ),
      )
    })
    ringScale.value = withRepeat(
      withSequence(
        withTiming(0.9, { duration: 700, easing: Easing.inOut(Easing.quad) }),
        withTiming(1.15, { duration: 700, easing: Easing.inOut(Easing.quad) }),
      ),
      -1,
      true,
    )
    ringOpacity.value = withRepeat(
      withSequence(
        withTiming(0.3, { duration: 700, easing: Easing.inOut(Easing.quad) }),
        withTiming(0.7, { duration: 700, easing: Easing.inOut(Easing.quad) }),
      ),
      -1,
      true,
    )
  }, [
    chatStatus,
    reduceMotion,
    bar0Scale,
    bar1Scale,
    bar2Scale,
    bar3Scale,
    ringScale,
    ringOpacity,
  ])

  const ringStyle = useAnimatedStyle(() => ({
    opacity: ringOpacity.value,
    transform: [{ scale: ringScale.value }],
  }))
  const bar0Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar0Scale.value }],
  }))
  const bar1Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar1Scale.value }],
  }))
  const bar2Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar2Scale.value }],
  }))
  const bar3Style = useAnimatedStyle(() => ({
    transform: [{ scaleY: bar3Scale.value }],
  }))

  const barColor = ORB_COLORS[chatStatus]
  const showRing = chatStatus === 'connecting' && !reduceMotion
  const showReducedMotionConnectingDot =
    chatStatus === 'connecting' && reduceMotion

  const handlePress = () => {
    if (!reduceMotion) {
      void Haptics.selectionAsync()
    }
    onPress()
  }

  return (
    <Pressable
      testID={testID ?? 'ai-chat-orb'}
      onPress={handlePress}
      accessibilityRole="button"
      accessibilityLabel={A11Y_LABELS[chatStatus]}
      accessibilityValue={{ text: A11Y_LABELS[chatStatus] }}
      accessibilityHint="Toggle the chat panel"
      hitSlop={4}
      style={style}
    >
      {showRing ? (
        <Animated.View
          testID="ai-chat-orb-ring"
          pointerEvents="none"
          accessible={false}
          style={[
            {
              position: 'absolute',
              top: -2,
              left: -2,
              width: RING_SIZE,
              height: RING_SIZE,
              borderRadius: RING_SIZE / 2,
              borderWidth: 2,
              borderColor: 'rgba(59,130,246,0.6)',
            },
            ringStyle,
          ]}
        />
      ) : null}
      <GlassDisk size={ORB_SIZE} tintColor={ORB_DISK_TINTS[chatStatus]}>
        <View
          style={{
            ...StyleSheet.absoluteFillObject,
            flexDirection: 'row',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 3,
          }}
          pointerEvents="none"
          accessible={false}
        >
          {[bar0Style, bar1Style, bar2Style, bar3Style].map((s, i) => (
            <Animated.View
              key={i}
              style={[
                {
                  width: 3,
                  height: BAR_HEIGHTS[i],
                  borderRadius: 1.5,
                  backgroundColor: barColor,
                },
                s,
              ]}
            />
          ))}
        </View>
        {showReducedMotionConnectingDot ? (
          <View
            pointerEvents="none"
            accessible={false}
            style={{
              position: 'absolute',
              top: 6,
              right: 6,
              width: 6,
              height: 6,
              borderRadius: 3,
              backgroundColor: 'rgba(59,130,246,0.9)',
            }}
          />
        ) : null}
      </GlassDisk>
    </Pressable>
  )
}
