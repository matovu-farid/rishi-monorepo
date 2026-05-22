import React from 'react'
import { Text, View, StyleSheet } from 'react-native'
import { useTheme } from '@/lib/theme'

export type ReaderProgress =
  | { kind: 'page'; current: number; total: number }
  | { kind: 'chapter'; current: number; total: number }
  | { kind: 'cfi'; label: string }
  | { kind: 'none' }

export interface ReaderProgressPillProps {
  progress: ReaderProgress
  testID?: string
}

function formatLabel(progress: ReaderProgress): string {
  switch (progress.kind) {
    case 'page':
      return `${progress.current} / ${progress.total}`
    case 'chapter':
      return `Ch ${progress.current}/${progress.total}`
    case 'cfi':
      return progress.label
    case 'none':
      return '—'
  }
}

export function ReaderProgressPill({
  progress,
  testID,
}: ReaderProgressPillProps): React.JSX.Element {
  const { colors, spacing, radius, typography } = useTheme()
  const label = formatLabel(progress)
  const footnote = typography.scale.footnote

  return (
    <View
      testID={testID}
      accessibilityLabel={label}
      style={[
        styles.pill,
        {
          backgroundColor: colors.fill.tertiary,
          borderRadius: radius.full,
          paddingVertical: spacing.xs,
          paddingHorizontal: spacing.md,
        },
      ]}
    >
      <Text
        style={{
          fontSize: footnote.fontSize,
          lineHeight: footnote.lineHeight,
          fontWeight: footnote.fontWeight,
          color: colors.label.secondary,
        }}
      >
        {label}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  pill: {
    alignSelf: 'center',
  },
})
