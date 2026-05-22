import React, { useEffect } from 'react'
import { View, Text, Pressable, StyleSheet } from 'react-native'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
} from 'react-native-reanimated'
import * as Haptics from 'expo-haptics'
import { useTheme } from '@/lib/theme'

export type SegmentedControlOption<T extends string> = {
  label: string
  value: T
}

export type SegmentedControlProps<T extends string> = {
  value: T
  onChange: (next: T) => void
  options: ReadonlyArray<SegmentedControlOption<T>>
  fullWidth?: boolean
  size?: 'sm' | 'md'
  testID?: string
}

export function SegmentedControl<T extends string>({
  value,
  onChange,
  options,
  fullWidth = false,
  size = 'md',
  testID,
}: SegmentedControlProps<T>): React.JSX.Element {
  const { colors, radius, motion, scheme, shadow, typography } = useTheme()
  const selectedIndex = Math.max(
    0,
    options.findIndex((o) => o.value === value),
  )
  const indicatorPosition = useSharedValue(selectedIndex)

  useEffect(() => {
    indicatorPosition.value = withSpring(selectedIndex, motion.spring.snappy)
  }, [selectedIndex, indicatorPosition, motion.spring.snappy])

  const height = size === 'md' ? 36 : 28
  const fontStyle = size === 'md' ? typography.scale.subhead : typography.scale.footnote
  const pillBackground =
    scheme === 'dark' ? colors.fill.tertiary : colors.background.primary

  const indicatorStyle = useAnimatedStyle(() => ({
    transform: [
      {
        translateX: `${indicatorPosition.value * 100}%`,
      },
    ],
  }))

  return (
    <View
      accessibilityRole="tablist"
      testID={testID}
      style={[
        {
          height,
          backgroundColor: colors.fill.primary,
          borderRadius: radius.lg,
          flexDirection: 'row',
          padding: 2,
          alignSelf: fullWidth ? 'stretch' : 'flex-start',
        },
      ]}
    >
      <Animated.View
        pointerEvents="none"
        style={[
          {
            position: 'absolute',
            top: 2,
            bottom: 2,
            left: 2,
            width: `${100 / options.length}%`,
            backgroundColor: pillBackground,
            borderRadius: radius.lg - 2,
          },
          shadow.low,
          indicatorStyle,
        ]}
      />
      {options.map((option) => {
        const selected = option.value === value
        return (
          <Pressable
            key={option.value}
            accessibilityRole="tab"
            accessibilityLabel={option.label}
            accessibilityState={{ selected }}
            onPress={() => {
              if (selected) return
              void Haptics.selectionAsync()
              onChange(option.value)
            }}
            style={[styles.segment]}
          >
            <Text
              style={{
                fontSize: fontStyle.fontSize,
                lineHeight: fontStyle.lineHeight,
                fontWeight: selected ? '600' : '400',
                color: colors.label.primary,
              }}
            >
              {option.label}
            </Text>
          </Pressable>
        )
      })}
    </View>
  )
}

const styles = StyleSheet.create({
  segment: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
})
