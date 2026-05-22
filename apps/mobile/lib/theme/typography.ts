import { Platform } from 'react-native'

export const typography = {
  family: Platform.select({
    ios: {
      sans: 'system-ui',
      serif: 'ui-serif',
      rounded: 'ui-rounded',
      mono: 'ui-monospace',
    },
    default: {
      sans: 'normal',
      serif: 'serif',
      rounded: 'normal',
      mono: 'monospace',
    },
  })!,
  weights: {
    regular: '400',
    medium: '500',
    semibold: '600',
    bold: '700',
  } as const,
  lineHeights: {
    tight: 1.2,
    normal: 1.4,
    relaxed: 1.5,
  } as const,
  scale: {
    // Apple HIG Large Title is Bold (700), not Semibold. The `largeTitle`
    // key below is a semantic alias kept in sync with `display-large`.
    'display-large': { fontSize: 34, fontWeight: '700' as const, lineHeight: 41, family: 'sans' as const },
    largeTitle: { fontSize: 34, fontWeight: '700' as const, lineHeight: 41, family: 'sans' as const },
    display: { fontSize: 28, fontWeight: '600' as const, lineHeight: 34, family: 'sans' as const },
    title: { fontSize: 22, fontWeight: '600' as const, lineHeight: 28, family: 'sans' as const },
    body: { fontSize: 17, fontWeight: '400' as const, lineHeight: 22, family: 'sans' as const },
    callout: { fontSize: 16, fontWeight: '400' as const, lineHeight: 21, family: 'sans' as const },
    subhead: { fontSize: 15, fontWeight: '400' as const, lineHeight: 20, family: 'sans' as const },
    footnote: { fontSize: 13, fontWeight: '400' as const, lineHeight: 18, family: 'sans' as const },
    caption: { fontSize: 12, fontWeight: '400' as const, lineHeight: 16, family: 'sans' as const },
    'caption-small': { fontSize: 11, fontWeight: '400' as const, lineHeight: 13, family: 'sans' as const },
    'reader-body': { fontSize: 17, fontWeight: '400' as const, lineHeight: 25.5, family: 'serif' as const },
  },
  // Apple HIG dynamic-type tracking (in points) — keep keys in sync with `scale`.
  // Reference: developer.apple.com/design/human-interface-guidelines/typography
  letterSpacing: {
    'display-large': 0.37,
    largeTitle: 0.37,
    display: 0.36,
    title: 0.35,
    body: -0.41,
    callout: -0.32,
    subhead: -0.24,
    footnote: -0.08,
    caption: 0,
    'caption-small': 0.07,
    'reader-body': -0.41,
  },
} as const

export type Typography = typeof typography
export type TypographyScaleKey = keyof typeof typography.scale
