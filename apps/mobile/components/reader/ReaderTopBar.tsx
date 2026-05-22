import React, { useEffect } from 'react'
import { Text, View } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
} from 'react-native-reanimated'
import { IconButton } from '@/components/ui/IconButton'
import { Toolbar } from '@/components/ui/Toolbar'
import { useTheme } from '@/lib/theme'

export interface ReaderTopBarProps {
  visible: boolean
  title: string
  onBack: () => void
  /**
   * Optional long-press handler on the Back chevron. Wired by
   * ReaderShell to flip the persistent `toolbarPinned` flag (P1-E).
   */
  onLongPressBack?: () => void
  /**
   * Mirrors `prefsStore.toolbarPinned`. Renders a subtle pin cue next
   * to the Back chevron so the user can tell the auto-hide is bypassed.
   */
  pinned?: boolean
  testID?: string
}

export function ReaderTopBar({
  visible,
  title,
  onBack,
  onLongPressBack,
  pinned = false,
  testID,
}: ReaderTopBarProps): React.JSX.Element {
  const { colors, typography, motion, reduceMotion } = useTheme()
  const opacity = useSharedValue(visible ? 1 : 0)

  useEffect(() => {
    opacity.value = withTiming(visible ? 1 : 0, {
      duration: reduceMotion ? 0 : motion.duration.fast,
    })
  }, [visible, opacity, motion.duration.fast, reduceMotion])

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
  }))

  const body = typography.scale.body

  // P1-E — when pinned, render a tinted pin glyph next to the Back
  // chevron. Purely visual; the long-press toggle lives on the chevron
  // itself. Tinted in the system accent so it's discoverable but quiet.
  const leftCluster = pinned ? (
    <View
      testID="reader-top-bar-pin-cue-container"
      style={{ flexDirection: 'row', alignItems: 'center' }}
    >
      <IconButton
        name="chevron-back"
        onPress={onBack}
        onLongPress={onLongPressBack}
        label="Back to library"
        haptic="light"
      />
      <View
        testID="reader-top-bar-pin-cue"
        accessibilityLabel="Toolbar pinned"
        style={{
          marginLeft: 4,
          width: 6,
          height: 6,
          borderRadius: 3,
          backgroundColor: colors.label.primary,
        }}
      />
    </View>
  ) : (
    <IconButton
      name="chevron-back"
      onPress={onBack}
      onLongPress={onLongPressBack}
      label="Back to library"
      haptic="light"
    />
  )

  return (
    <Animated.View
      pointerEvents={visible ? 'auto' : 'none'}
      testID={testID}
      style={[
        {
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          zIndex: 10,
        },
        animatedStyle,
      ]}
    >
      <Toolbar
        position="top"
        blur
        transparent
        hairline
        left={leftCluster}
        center={
          <Text
            numberOfLines={1}
            style={{
              fontSize: body.fontSize,
              lineHeight: body.lineHeight,
              fontWeight: '600',
              color: colors.label.primary,
              textAlign: 'center',
            }}
          >
            {title}
          </Text>
        }
      />
    </Animated.View>
  )
}
