import { useColorScheme, AccessibilityInfo } from 'react-native'
import { useEffect, useState, useMemo } from 'react'
import { colorsLight, colorsDark, type ColorTokens } from './colors'
import { typography, type Typography } from './typography'
import {
  spacing,
  radius,
  motion,
  shadow,
  type Spacing,
  type Radius,
  type Motion,
  type Shadow,
} from './tokens'

export type Theme = {
  scheme: 'light' | 'dark'
  colors: ColorTokens
  typography: Typography
  spacing: Spacing
  radius: Radius
  motion: Motion
  shadow: Shadow
  reduceMotion: boolean
}

export function useTheme(): Theme {
  const systemScheme = useColorScheme() ?? 'light'
  const [reduceMotion, setReduceMotion] = useState(false)

  useEffect(() => {
    let cancelled = false
    void AccessibilityInfo.isReduceMotionEnabled().then((v) => {
      if (!cancelled) setReduceMotion(v)
    })
    const sub = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      setReduceMotion,
    )
    return () => {
      cancelled = true
      sub.remove()
    }
  }, [])

  return useMemo(
    () => ({
      scheme: systemScheme,
      colors: systemScheme === 'dark' ? colorsDark : colorsLight,
      typography,
      spacing,
      radius,
      motion,
      shadow,
      reduceMotion,
    }),
    [systemScheme, reduceMotion],
  )
}
