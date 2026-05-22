import React, { useState } from 'react'
import { View, Text, TextInput, StyleSheet } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withTiming,
} from 'react-native-reanimated'
import { useTheme } from '@/lib/theme'
import { IconButton } from './IconButton'
import { PressableScale } from './PressableScale'

export type SearchBarProps = {
  value: string
  onChange: (next: string) => void
  placeholder?: string
  onClear?: () => void
  onCancel?: () => void
  onSubmit?: () => void
  autoFocus?: boolean
  testID?: string
}

export function SearchBar({
  value,
  onChange,
  placeholder = 'Search',
  onClear,
  onCancel,
  onSubmit,
  autoFocus,
  testID,
}: SearchBarProps): React.JSX.Element {
  const { colors, radius, spacing, motion, typography } = useTheme()
  const [focused, setFocused] = useState(false)
  const cancelWidth = useSharedValue(0)

  const cancelStyle = useAnimatedStyle(() => ({
    width: cancelWidth.value,
    opacity: cancelWidth.value === 0 ? 0 : 1,
  }))

  const showCancel = Boolean(onCancel) && focused

  const handleFocus = () => {
    setFocused(true)
    if (onCancel) {
      cancelWidth.value = withTiming(72, { duration: motion.duration.normal })
    }
  }

  const handleBlur = () => {
    setFocused(false)
    if (onCancel) {
      cancelWidth.value = withTiming(0, { duration: motion.duration.normal })
    }
  }

  const handleClear = () => {
    onClear ? onClear() : onChange('')
  }

  const handleCancel = () => {
    if (onCancel) {
      onChange('')
      cancelWidth.value = withTiming(0, { duration: motion.duration.normal })
      onCancel()
    }
  }

  const bodyStyle = typography.scale.body

  return (
    <View style={styles.row} testID={testID}>
      <View
        style={[
          styles.bar,
          {
            backgroundColor: colors.fill.secondary,
            borderRadius: radius.lg,
            paddingHorizontal: spacing.md,
          },
        ]}
      >
        <Ionicons
          name="search"
          size={16}
          color={colors.label.tertiary}
          style={{ marginRight: spacing.xs }}
        />
        <TextInput
          accessibilityLabel="Search"
          value={value}
          onChangeText={onChange}
          onSubmitEditing={onSubmit}
          onFocus={handleFocus}
          onBlur={handleBlur}
          placeholder={placeholder}
          placeholderTextColor={colors.label.tertiary}
          returnKeyType="search"
          autoFocus={autoFocus}
          style={{
            flex: 1,
            fontSize: bodyStyle.fontSize,
            lineHeight: bodyStyle.lineHeight,
            color: colors.label.primary,
          }}
        />
        {value.length > 0 ? (
          <IconButton
            name="close-circle"
            size={16}
            color={colors.label.tertiary}
            label="Clear search"
            onPress={handleClear}
          />
        ) : null}
      </View>
      {showCancel ? (
        <Animated.View style={[cancelStyle, styles.cancel]}>
          <PressableScale
            onPress={handleCancel}
            accessibilityLabel="Cancel"
          >
            <Text style={{ color: colors.accent.primary, fontSize: bodyStyle.fontSize }}>
              Cancel
            </Text>
          </PressableScale>
        </Animated.View>
      ) : null}
    </View>
  )
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  bar: {
    flex: 1,
    height: 36,
    flexDirection: 'row',
    alignItems: 'center',
  },
  cancel: {
    paddingLeft: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
})
