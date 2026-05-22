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

  const baseStyle: ViewStyle =
    orientation === 'horizontal'
      ? {
          height: StyleSheet.hairlineWidth,
          width: '100%',
          marginLeft: inset,
          backgroundColor,
        }
      : {
          width: StyleSheet.hairlineWidth,
          height: '100%',
          marginTop: inset,
          backgroundColor,
        }

  return <View accessible={false} style={[baseStyle, style]} />
}
