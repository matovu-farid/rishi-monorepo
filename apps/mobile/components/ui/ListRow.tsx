import React from 'react'
import { View, Text, Switch, StyleSheet } from 'react-native'
import Ionicons from '@expo/vector-icons/Ionicons'
import { useTheme } from '@/lib/theme'
import { PressableScale } from './PressableScale'

export type ListRowAccessory =
  | 'chevron'
  | 'check'
  | { kind: 'switch'; value: boolean; onValueChange: (next: boolean) => void }
  | { kind: 'custom'; node: React.ReactNode }

export type ListRowProps = {
  icon?: React.ReactNode
  title: string
  subtitle?: string
  accessory?: ListRowAccessory
  value?: string
  onPress?: () => void
  destructive?: boolean
  testID?: string
}

function renderAccessory(
  accessory: ListRowAccessory | undefined,
  colors: ReturnType<typeof useTheme>['colors'],
): React.ReactNode {
  if (!accessory) return null
  if (accessory === 'chevron') {
    return (
      <Ionicons
        name="chevron-forward"
        size={16}
        color={colors.label.tertiary}
      />
    )
  }
  if (accessory === 'check') {
    return (
      <Ionicons name="checkmark" size={20} color={colors.accent.primary} />
    )
  }
  if (accessory.kind === 'switch') {
    return (
      <Switch
        value={accessory.value}
        onValueChange={accessory.onValueChange}
        trackColor={{ true: colors.accent.primary, false: colors.fill.primary }}
        thumbColor="#FFFFFF"
      />
    )
  }
  return accessory.node
}

export function ListRow({
  icon,
  title,
  subtitle,
  accessory,
  value,
  onPress,
  destructive = false,
  testID,
}: ListRowProps): React.JSX.Element {
  const { colors, spacing, typography } = useTheme()
  const titleColor = destructive ? colors.accent.error : colors.label.primary

  const body = (
    <View
      style={[
        styles.row,
        {
          paddingVertical: spacing.sm,
          paddingHorizontal: spacing.lg,
        },
      ]}
    >
      {icon ? <View style={{ marginRight: spacing.sm }}>{icon}</View> : null}
      <View style={styles.titleColumn}>
        <Text
          style={{
            fontSize: typography.scale.body.fontSize,
            lineHeight: typography.scale.body.lineHeight,
            color: titleColor,
          }}
        >
          {title}
        </Text>
        {subtitle ? (
          <Text
            style={{
              fontSize: typography.scale.subhead.fontSize,
              lineHeight: typography.scale.subhead.lineHeight,
              color: colors.label.secondary,
            }}
          >
            {subtitle}
          </Text>
        ) : null}
      </View>
      {value ? (
        <Text
          style={{
            fontSize: typography.scale.subhead.fontSize,
            color: colors.label.secondary,
            marginRight: spacing.sm,
          }}
        >
          {value}
        </Text>
      ) : null}
      {renderAccessory(accessory, colors)}
    </View>
  )

  if (!onPress) {
    return (
      <View testID={testID} accessible={accessory && typeof accessory === 'object' && accessory.kind === 'switch' ? false : undefined}>
        {body}
      </View>
    )
  }

  const accessibilityLabel = destructive
    ? `${title}, destructive action`
    : title

  return (
    <PressableScale
      onPress={onPress}
      scale={0.99}
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={subtitle}
      testID={testID}
    >
      {body}
    </PressableScale>
  )
}

const styles = StyleSheet.create({
  row: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
  },
  titleColumn: {
    flex: 1,
  },
})
