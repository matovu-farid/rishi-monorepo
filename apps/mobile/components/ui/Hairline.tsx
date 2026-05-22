import React from 'react'
import { View, StyleSheet, type ViewStyle } from 'react-native'
import { useTheme } from '@/lib/theme'

export type HairlineProps = {
  orientation?: 'horizontal' | 'vertical'
  color?: string
  inset?: number
  style?: ViewStyle
}

export function Hairline({
  orientation = 'horizontal',
  color,
  inset = 0,
  style,
}: HairlineProps): React.JSX.Element {
  const { colors } = useTheme()
  const backgroundColor = color ?? colors.separator.nonOpaque

  // `alignSelf: 'stretch'` rather than `width/height: '100%'` so that
  // `marginLeft`/`marginTop: inset` shrinks the divider into the remaining
  // axis-cross space instead of overflowing the parent by `inset` pt.
  const baseStyle: ViewStyle =
    orientation === 'horizontal'
      ? {
          height: StyleSheet.hairlineWidth,
          alignSelf: 'stretch',
          marginLeft: inset,
          backgroundColor,
        }
      : {
          width: StyleSheet.hairlineWidth,
          alignSelf: 'stretch',
          marginTop: inset,
          backgroundColor,
        }

  return <View accessible={false} style={[baseStyle, style]} />
}
