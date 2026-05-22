import React from 'react'
import { View, StyleSheet } from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { useTheme } from '@/lib/theme'
import { Hairline } from './Hairline'

export type ToolbarProps = {
  position: 'top' | 'bottom'
  left?: React.ReactNode
  center?: React.ReactNode
  right?: React.ReactNode
  transparent?: boolean
  blur?: boolean
  hairline?: boolean
  testID?: string
}

export function Toolbar({
  position,
  left,
  center,
  right,
  transparent = false,
  // TODO Phase 3: replace rgba fallback with <BlurView> once app.json plugin lands.
  blur = false,
  hairline = true,
  testID,
}: ToolbarProps): React.JSX.Element {
  const { colors, scheme, spacing } = useTheme()
  const insets = useSafeAreaInsets()

  const fallbackBackground =
    transparent || blur
      ? scheme === 'dark'
        ? 'rgba(28,28,30,0.95)'
        : 'rgba(255,255,255,0.95)'
      : colors.background.primary

  const containerStyle = {
    backgroundColor: fallbackBackground,
    paddingTop: position === 'top' ? insets.top : 0,
    paddingBottom: position === 'bottom' ? insets.bottom : 0,
    paddingHorizontal: spacing.lg,
  }

  return (
    <View
      accessibilityRole="toolbar"
      testID={testID}
      style={[styles.container, containerStyle]}
    >
      {position === 'bottom' && hairline ? <Hairline /> : null}
      <View style={styles.row}>
        <View style={styles.sideSlot}>{left}</View>
        <View pointerEvents="box-none" style={styles.centerSlot}>
          {center}
        </View>
        <View style={[styles.sideSlot, styles.rightSlot]}>{right}</View>
      </View>
      {position === 'top' && hairline ? <Hairline /> : null}
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    width: '100%',
  },
  row: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
  },
  sideSlot: {
    flexDirection: 'row',
    alignItems: 'center',
    zIndex: 1,
  },
  rightSlot: {
    marginLeft: 'auto',
  },
  centerSlot: {
    position: 'absolute',
    left: 0,
    right: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
})
