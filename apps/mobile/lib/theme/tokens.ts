// Pure numeric/structural tokens. No colors, no Platform imports.

export const spacing = {
  none: 0,
  xxs: 2,
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 20,
  '2xl': 24,
  '3xl': 32,
  '4xl': 40,
  '5xl': 56,
  '6xl': 80,
} as const

export const radius = {
  none: 0,
  sm: 6,
  md: 10,
  lg: 14,
  xl: 20,
  full: 9999,
  // Semantic aliases (P1-Y). Keep t-shirt keys above untouched — these are
  // additive so existing consumers (e.g. radius.md) stay green.
  cover: 8, // book cover corner radius
  card: 12, // card / row container radius
  sheet: 22, // modal / bottom-sheet top radius (iOS sheet feel)
} as const

export const motion = {
  // Raw Reanimated coefficients — hand-tuned to match Apple Books feel.
  // Do NOT algebra-convert to damping ratios; use these numbers directly.
  spring: {
    gentle: { damping: 18, stiffness: 250, mass: 1 },
    snappy: { damping: 22, stiffness: 400, mass: 1 },
    bouncy: { damping: 12, stiffness: 200, mass: 1 },
  },
  duration: {
    fast: 200,
    normal: 300,
    slow: 500,
    // Semantic durations for repeating "breathing" / "spinner" loops.
    // Distinct from the fast/normal/slow UI-transition triad because they
    // describe a *period*, not a one-shot tween.
    //  - pulse:  voice-button breathing & TTS cue heartbeat (~ Apple Books
    //            voice-active state).
    //  - pulseFast: secondary pulse for the "speaking" sub-state where the
    //            cadence needs to feel more responsive than `pulse`.
    //  - rotate: full revolution period for an indeterminate spinner
    //            (sync indicator + reader spinner).
    pulse: 800,
    pulseFast: 600,
    rotate: 1000,
  },
} as const

// P1-M — shared z-index scale for the reader chrome stack. Inline values
// drifted across files (orb/launcher at 20, bottom bar at 10, sheets ad-hoc)
// and produced overlap regressions. Consumers must pull from this scale so
// the layering invariant `toolbar < overlayChrome < sheet` holds globally.
export const zIndex = {
  toolbar: 10,
  overlayChrome: 20,
  sheet: 30,
} as const

export const shadow = {
  flat: {
    shadowColor: '#000',
    shadowOpacity: 0,
    shadowRadius: 0,
    shadowOffset: { width: 0, height: 0 },
    elevation: 0,
  },
  low: {
    shadowColor: '#000',
    shadowOpacity: 0.06,
    shadowRadius: 2,
    shadowOffset: { width: 0, height: 1 },
    elevation: 1,
  },
  medium: {
    shadowColor: '#000',
    shadowOpacity: 0.12,
    shadowRadius: 14,
    shadowOffset: { width: 0, height: 6 },
    elevation: 8,
  },
  high: {
    shadowColor: '#000',
    shadowOpacity: 0.18,
    shadowRadius: 28,
    shadowOffset: { width: 0, height: 12 },
    elevation: 16,
  },
} as const

export type Spacing = typeof spacing
export type Radius = typeof radius
export type Motion = typeof motion
export type Shadow = typeof shadow
export type ZIndex = typeof zIndex
export type SpacingKey = keyof Spacing
export type RadiusKey = keyof Radius
export type ZIndexKey = keyof ZIndex
