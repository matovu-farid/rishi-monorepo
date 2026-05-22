import React from 'react'
import { View, Text, StyleSheet } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'
import * as Haptics from 'expo-haptics'
import { useTheme } from '@/lib/theme'
import { PressableScale } from './PressableScale'

export type EmptyStateProps = {
  icon: keyof typeof Ionicons.glyphMap | React.ReactNode
  title: string
  description?: string
  action?: { label: string; onPress: () => void; testID?: string; disabled?: boolean }
  /**
   * VIS-013: optional override for the icon color. Defaults to
   * `colors.label.secondary` (HIG empty-state glyph tint).
   */
  tint?: string
  testID?: string
  titleTestID?: string
}

export function EmptyState({
  icon,
  title,
  description,
  action,
  tint,
  testID,
  titleTestID,
}: EmptyStateProps): React.JSX.Element {
  const { colors, spacing, typography, radius } = useTheme()
  // VIS-013: Apple empty-state glyphs are 50pt at `label.secondary` (~60%),
  // not 56pt at `label.tertiary` (~30%). Callers can override via `tint`.
  const iconColor = tint ?? colors.label.secondary
  const iconNode =
    typeof icon === 'string' ? (
      <Ionicons
        name={icon as keyof typeof Ionicons.glyphMap}
        size={50}
        color={iconColor}
      />
    ) : (
      icon
    )

  const handleAction = () => {
    if (!action) return
    void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)
    action.onPress()
  }

  return (
    <View
      accessibilityRole="summary"
      testID={testID}
      style={[
        styles.container,
        {
          paddingHorizontal: spacing['2xl'],
          paddingTop: spacing['5xl'],
        },
      ]}
    >
      <View style={{ marginBottom: spacing.xl }}>{iconNode}</View>
      <Text
        testID={titleTestID}
        style={[
          styles.center,
          {
            fontSize: typography.scale.title.fontSize,
            lineHeight: typography.scale.title.lineHeight,
            fontWeight: typography.scale.title.fontWeight,
            color: colors.label.primary,
            marginBottom: spacing.xl,
          },
        ]}
      >
        {title}
      </Text>
      {description ? (
        <Text
          style={[
            styles.center,
            {
              fontSize: typography.scale.body.fontSize,
              lineHeight: typography.scale.body.lineHeight,
              color: colors.label.secondary,
              maxWidth: 320,
              marginBottom: spacing.xl,
            },
          ]}
        >
          {description}
        </Text>
      ) : null}
      {action ? (
        <PressableScale
          onPress={handleAction}
          accessibilityLabel={action.label}
          testID={action.testID}
          disabled={action.disabled}
        >
          <View
            style={{
              height: 44,
              paddingHorizontal: spacing['2xl'],
              borderRadius: radius.full,
              backgroundColor: colors.accent.primary,
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <Text
              style={{
                color: '#FFFFFF',
                fontSize: typography.scale.body.fontSize,
                fontWeight: '600',
              }}
            >
              {action.label}
            </Text>
          </View>
        </PressableScale>
      ) : null}
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
  },
  center: {
    textAlign: 'center',
  },
})
