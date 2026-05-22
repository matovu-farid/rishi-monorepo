/**
 * Phase 2 — Mobile design-system tokens.
 *
 * `apps/mobile/lib/theme/{colors,typography,tokens}.ts` are the canonical
 * source for every chrome surface in the app. Once consumed by primitives
 * (Sheet, Toolbar, IconButton, etc.) any drift here is visible everywhere
 * at once, so these tests pin the values explicitly.
 *
 * The structural assertions (same keys in light/dark) prevent the worst
 * regression: shipping a dark mode that's silently missing colours, which
 * RN renders as `undefined` ➜ black text on black background.
 *
 * No mocks needed — token modules are pure constants. `react-native`'s
 * `Platform.select` inside typography is mocked at module level so the
 * file can be imported under Jest's Node test VM.
 */

// `typography` imports `Platform` from react-native; stub it so the
// module loads under Node without the RN preset.
jest.mock('react-native', () => ({
  Platform: {
    OS: 'ios',
    // The token module uses Platform.select; mirror real behaviour.
    select: <T,>(spec: Record<string, T>): T | undefined =>
      spec.ios ?? spec.default,
  },
  StyleSheet: { hairlineWidth: 0.5 },
}))

import { colorsLight, colorsDark } from '@/lib/theme/colors'
import { spacing, radius, motion, shadow } from '@/lib/theme/tokens'
import { typography } from '@/lib/theme/typography'

describe('colors (light/dark parity)', () => {
  it('light palette has all required top-level keys', () => {
    expect(colorsLight).toHaveProperty('background')
    expect(colorsLight).toHaveProperty('label')
    expect(colorsLight).toHaveProperty('fill')
    expect(colorsLight).toHaveProperty('separator')
    expect(colorsLight).toHaveProperty('accent')
    expect(colorsLight).toHaveProperty('reader')
    expect(colorsLight).toHaveProperty('highlight')
  })

  it('dark palette mirrors the same top-level keys as light', () => {
    expect(Object.keys(colorsDark).sort()).toEqual(
      Object.keys(colorsLight).sort(),
    )
  })

  it('dark palette mirrors every nested key inside each group', () => {
    // If a leaf is added to light but forgotten in dark, RN renders
    // `undefined` ➜ default black. Catch that here at unit-test time.
    for (const group of Object.keys(colorsLight) as Array<
      keyof typeof colorsLight
    >) {
      const lightKeys = Object.keys(colorsLight[group]).sort()
      const darkKeys = Object.keys(
        colorsDark[group as keyof typeof colorsDark],
      ).sort()
      expect(darkKeys).toEqual(lightKeys)
    }
  })

  it('every color value is a non-empty string', () => {
    const collect = (
      palette: typeof colorsLight | typeof colorsDark,
    ): string[] => {
      const out: string[] = []
      for (const group of Object.values(palette as Record<string, Record<string, string>>)) {
        for (const value of Object.values(group)) {
          out.push(value)
        }
      }
      return out
    }
    for (const value of [...collect(colorsLight), ...collect(colorsDark)]) {
      expect(typeof value).toBe('string')
      expect(value.length).toBeGreaterThan(0)
    }
  })

  it('accent.primary holds the Apple-Books-tuned brand teal in each scheme', () => {
    // Sentinel — UI-SPEC §1.1/§1.2 fix these so chrome accents stay legible.
    expect(colorsLight.accent.primary).toBe('#0a7ea4')
    expect(colorsDark.accent.primary).toBe('#3AB4D6')
  })
})

describe('spacing scale (4pt grid)', () => {
  it('exposes the documented keys from UI-SPEC §3', () => {
    // UI-SPEC §3 names tokens by t-shirt size. Keep this list in sync;
    // these are the keys callers depend on.
    for (const key of [
      'none',
      'xxs',
      'xs',
      'sm',
      'md',
      'lg',
      'xl',
      '2xl',
      '3xl',
      '4xl',
      '5xl',
      '6xl',
    ] as const) {
      expect(spacing).toHaveProperty(key)
    }
  })

  it('is monotonically increasing in declaration order', () => {
    // The token order in `spacing` (none → 6xl) must walk up monotonically;
    // any reversal or duplicate hints at a copy-paste bug.
    const values = Object.values(spacing) as number[]
    for (let i = 1; i < values.length; i++) {
      expect(values[i]).toBeGreaterThan(values[i - 1])
    }
  })

  it('every value is a non-negative number', () => {
    for (const value of Object.values(spacing) as number[]) {
      expect(typeof value).toBe('number')
      expect(value).toBeGreaterThanOrEqual(0)
    }
  })
})

describe('radius scale', () => {
  it('md is 10pt — the canonical book-cover / card radius', () => {
    expect(radius.md).toBe(10)
  })

  it('full is ≥ 9999 — the "pill" sentinel', () => {
    expect(radius.full).toBeGreaterThanOrEqual(9999)
  })

  it('every value is a non-negative number', () => {
    for (const value of Object.values(radius) as number[]) {
      expect(typeof value).toBe('number')
      expect(value).toBeGreaterThanOrEqual(0)
    }
  })
})

describe('typography (iOS HIG scale)', () => {
  it('display-large size is 34pt', () => {
    // Sentinel — Apple Books-style large titles ("Library") use 34pt.
    expect(typography.scale['display-large'].fontSize).toBe(34)
  })

  it('display-large weight is 700 — Apple HIG Large Title is Bold', () => {
    // P1-W: HIG specifies Large Title weight is Bold (700), not Semibold.
    expect(typography.scale['display-large'].fontWeight).toBe('700')
  })

  it('exposes a `largeTitle` semantic alias mapping to display-large', () => {
    // P1-W: HIG-named alias so consumers can write `scale.largeTitle`
    // alongside the existing `display-large` key.
    expect(typography.scale).toHaveProperty('largeTitle')
    expect(typography.scale.largeTitle).toEqual(
      typography.scale['display-large'],
    )
  })

  it('exposes a letterSpacing table per Apple HIG dynamic-type tracking', () => {
    // P1-W: HIG tracking values for each text style (in points).
    // Reference: developer.apple.com/design/human-interface-guidelines/typography
    expect(typography.letterSpacing).toBeDefined()
    expect(typography.letterSpacing['display-large']).toBeCloseTo(0.37, 2)
    expect(typography.letterSpacing.largeTitle).toBeCloseTo(0.37, 2)
    // Title 1 / Title 2 / Title 3 (we map our "display" + "title" tokens).
    expect(typography.letterSpacing.display).toBeCloseTo(0.36, 2)
    expect(typography.letterSpacing.title).toBeCloseTo(0.35, 2)
    // Body / callout / subhead / footnote / caption have negative tracking.
    expect(typography.letterSpacing.body).toBeCloseTo(-0.41, 2)
    expect(typography.letterSpacing.callout).toBeCloseTo(-0.32, 2)
    expect(typography.letterSpacing.subhead).toBeCloseTo(-0.24, 2)
    expect(typography.letterSpacing.footnote).toBeCloseTo(-0.08, 2)
    expect(typography.letterSpacing.caption).toBe(0)
    expect(typography.letterSpacing['caption-small']).toBeCloseTo(0.07, 2)
  })

  it('body size is 17pt', () => {
    expect(typography.scale.body.fontSize).toBe(17)
  })

  it('caption-small size is 11pt', () => {
    expect(typography.scale['caption-small'].fontSize).toBe(11)
  })

  it('weight tokens map to numeric string CSS weights', () => {
    expect(typography.weights.regular).toBe('400')
    expect(typography.weights.semibold).toBe('600')
  })
})

describe('motion vocabulary', () => {
  it('spring.gentle has numeric damping/stiffness/mass coefficients', () => {
    // Reanimated 4 spring shape — these are raw coefficients, not ratios.
    expect(typeof motion.spring.gentle.damping).toBe('number')
    expect(typeof motion.spring.gentle.stiffness).toBe('number')
    expect(typeof motion.spring.gentle.mass).toBe('number')
  })

  it('duration.fast is 200ms (UI-SPEC §5 snappy chrome reveal)', () => {
    // UI-SPEC §5 fixes `timing.fast.duration = 200ms`. Exposed here as
    // `motion.duration.fast` so non-Reanimated consumers can read the
    // raw number without spelunking through a spring config.
    expect(motion.duration.fast).toBe(200)
  })
})

describe('shadow tokens (Apple Books restraint)', () => {
  it('low has the documented book-cover lift values', () => {
    // Sentinel from UI-SPEC §6.1.
    expect(shadow.low.shadowOpacity).toBeCloseTo(0.06, 4)
  })

  it('flat is a true zero-shadow', () => {
    expect(shadow.flat.shadowOpacity).toBe(0)
  })
})
