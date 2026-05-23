import React, { useEffect, useState } from 'react'
import { AccessibilityInfo, View, StyleSheet } from 'react-native'
import { BlurView } from 'expo-blur'
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
  blur = false,
  hairline = true,
  testID,
}: ToolbarProps): React.JSX.Element {
  const { colors, scheme, spacing } = useTheme()
  const insets = useSafeAreaInsets()

  // A11Y-008 (#105) — when the platform reports high text contrast we
  // swap the translucent rgba fallback for a SOLID themed background so
  // the toolbar reads cleanly against any page content underneath. The
  // BlurView still renders on top on iOS, but the opaque base keeps the
  // contrast ratio high for users who have opted in to high contrast.
  const [highContrast, setHighContrast] = useState(false)
  useEffect(() => {
    let cancelled = false
    const api = AccessibilityInfo as typeof AccessibilityInfo & {
      isHighTextContrastEnabled?: () => Promise<boolean>
    }
    if (typeof api.isHighTextContrastEnabled === 'function') {
      void api.isHighTextContrastEnabled().then((v) => {
        if (!cancelled) setHighContrast(v)
      })
    }
    // RN's `highTextContrastChanged` event is Android-only; on iOS the
    // listener is a no-op which is fine — we just stay on the default
    // translucent fallback. Cast the event name to keep this resilient
    // to RN type-narrowing changes across versions.
    const addListener = AccessibilityInfo.addEventListener as unknown as (
      event: string,
      cb: (value: boolean) => void,
    ) => { remove: () => void }
    const sub = addListener('highTextContrastChanged', (v) => {
      setHighContrast(v)
    })
    return () => {
      cancelled = true
      sub.remove()
    }
  }, [])

  // Translucent rgba sits BEHIND the BlurView so non-iOS / reduced-transparency
  // / web fallback users still see a coherent chrome surface. iOS picks up the
  // real vibrancy material via BlurView (P0-S: Apple-glass parity).
  const fallbackBackground =
    transparent || blur
      ? highContrast
        ? colors.background.primary
        : scheme === 'dark'
          ? 'rgba(28,28,30,0.95)'
          : 'rgba(255,255,255,0.95)'
      : colors.background.primary

  const blurTint =
    scheme === 'dark' ? 'systemChromeMaterialDark' : 'systemChromeMaterial'

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
      {blur ? (
        <BlurView
          intensity={80}
          tint={blurTint}
          style={StyleSheet.absoluteFill}
          accessible={false}
        />
      ) : null}
      {position === 'bottom' && hairline ? <Hairline /> : null}
      <View style={styles.row}>
        <View style={[styles.sideSlot, styles.leftSlot]}>{left}</View>
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
  // RDR-016 — side slots keep their intrinsic width but never grow, so
  // the centerSlot's `flex: 1` always wins the remaining space and long
  // titles / progress pills stop rendering behind the right cluster.
  sideSlot: {
    flexDirection: 'row',
    alignItems: 'center',
    flexShrink: 0,
    flexGrow: 0,
    zIndex: 1,
  },
  leftSlot: {
    justifyContent: 'flex-start',
  },
  rightSlot: {
    justifyContent: 'flex-end',
  },
  // RDR-016 — flex: 1 in the row so the center cluster takes whatever
  // horizontal space is left between the side slots. Previously this used
  // `position: absolute; left: 0; right: 0` which overlapped the rightSlot.
  centerSlot: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
})
