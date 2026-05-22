import React from 'react'
import { StyleSheet, View, useColorScheme, type ViewStyle } from 'react-native'
import { BlurView } from 'expo-blur'

import { shadow } from '@/lib/theme'

export interface GlassDiskProps {
  size: number
  tintColor?: string
  children?: React.ReactNode
  testID?: string
  style?: ViewStyle
}

/**
 * Apple-Books-style glass disk: shadowed wrapper + rounded clip + BlurView.
 *
 * Shadows do not survive `overflow:'hidden'` on iOS, so the shadow lives on
 * the outer View and the clip lives on the inner View. Both BlurView and
 * the hairline border + optional tint overlay are siblings inside the clip.
 */
export function GlassDisk({
  size,
  tintColor,
  children,
  testID,
  style,
}: GlassDiskProps): React.JSX.Element {
  const scheme = useColorScheme() ?? 'light'
  const blurTint = scheme === 'dark' ? 'systemMaterialDark' : 'systemMaterial'
  const borderColor =
    scheme === 'dark' ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.45)'

  return (
    <View testID={testID} style={[shadow.medium, style]}>
      <View
        style={{
          width: size,
          height: size,
          borderRadius: size / 2,
          overflow: 'hidden',
        }}
      >
        <BlurView
          intensity={80}
          tint={blurTint}
          style={StyleSheet.absoluteFill}
          accessible={false}
        />
        {tintColor ? (
          <View
            style={[StyleSheet.absoluteFill, { backgroundColor: tintColor }]}
            pointerEvents="none"
            accessible={false}
          />
        ) : null}
        <View
          style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            borderRadius: size / 2,
            borderWidth: StyleSheet.hairlineWidth,
            borderColor,
          }}
          pointerEvents="none"
          accessible={false}
        />
        {children}
      </View>
    </View>
  )
}
