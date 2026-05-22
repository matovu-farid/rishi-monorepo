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

  return useMemo(() => {
    // VIS-018: dark-mode iOS shadows are nearly invisible against `#000`
    // backgrounds. Apple Books leans harder on opacity (and on hairline
    // rims) to keep the elevation cue alive. We tune the visible
    // elevations upward in dark mode while `flat` stays a true zero.
    const tunedShadow: Shadow =
      systemScheme === 'dark'
        ? {
            flat: shadow.flat,
            low: { ...shadow.low, shadowOpacity: 0.5 },
            medium: { ...shadow.medium, shadowOpacity: 0.55 },
            high: { ...shadow.high, shadowOpacity: 0.6 },
          }
        : shadow
    return {
      scheme: systemScheme,
      colors: systemScheme === 'dark' ? colorsDark : colorsLight,
      typography,
      spacing,
      radius,
      motion,
      shadow: tunedShadow,
      reduceMotion,
    }
  }, [systemScheme, reduceMotion])
}
