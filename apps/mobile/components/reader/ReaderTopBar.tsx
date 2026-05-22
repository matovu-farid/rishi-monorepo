import React, { useEffect } from 'react'
import { Text } from 'react-native'
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
  testID?: string
}

export function ReaderTopBar({
  visible,
  title,
  onBack,
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
        left={
          <IconButton
            name="chevron-back"
            onPress={onBack}
            label="Back to library"
            haptic="light"
          />
        }
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
