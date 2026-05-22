# Phase 2 — Design System Foundation: ARCH.md

**Date:** 2026-05-22
**Author:** architect agent
**Status:** Ready for tester (red) then coder (green)
**Working dir:** `.parity-v2/phase2-design-system/`

---

## 0. Ground truth confirmed (read before writing a line of code)

Every claim below cites the file and line that was verified.

| Fact | Evidence |
|---|---|
| `expo-image@~3.0.11` already installed | `apps/mobile/package.json:37` |
| `expo-blur` NOT installed (not in deps) | `apps/mobile/package.json` — absent |
| `expo-blur` NOT in `app.json` plugins array | `apps/mobile/app.json:323-346` — plugins are `expo-router, expo-secure-store, expo-web-browser, expo-splash-screen, expo-sqlite, @sentry/react-native/expo` |
| `@gorhom/bottom-sheet@^5.2.8` installed | `apps/mobile/package.json:18` |
| `react-native-reanimated@~4.1.1` installed | `apps/mobile/package.json:63` |
| `expo-haptics@~15.0.8` installed | `apps/mobile/package.json:32` |
| `@expo/vector-icons@^15.0.3` (Ionicons) installed | `apps/mobile/package.json:17` |
| `react-native-safe-area-context@~5.6.0` installed | `apps/mobile/package.json:64` |
| NativeWind v4 installed, zero custom tokens | `apps/mobile/tailwind.config.js:1-10` |
| `use-color-scheme.ts` re-exports RN's `useColorScheme` | `apps/mobile/hooks/use-color-scheme.ts:1` |
| `use-theme-color.ts` reads `useColorScheme()` + `Colors` from `constants/theme.ts` | `apps/mobile/hooks/use-theme-color.ts:1-21` |
| `constants/theme.ts` has `Colors` (6 roles light/dark) + `Fonts` (Platform.select) | `apps/mobile/constants/theme.ts:11-53` |
| `components/themed-text.tsx` uses `useThemeColor` + hardcoded font sizes | `apps/mobile/components/themed-text.tsx:1-60` |
| `components/themed-view.tsx` uses `useThemeColor` for background | `apps/mobile/components/themed-view.tsx:1-14` |
| `components/ui/icon-symbol.tsx` uses `MaterialIcons` (SF Symbols mapping) | `apps/mobile/components/ui/icon-symbol.tsx:1-75` |
| `BookRow.tsx` uses `Image` from RN, NativeWind classes, `IconSymbol` | `apps/mobile/components/BookRow.tsx:1-70` |
| `app/(tabs)/index.tsx` uses `Image` from RN, NativeWind classes for covers | `apps/mobile/app/(tabs)/index.tsx:170-188` |
| `PremiumFeatureSheet` uses `BottomSheet` (not `BottomSheetModal`) with `index={-1}` pattern | `apps/mobile/components/auth/PremiumFeatureSheet.tsx:133-136` |
| Root `_layout.tsx` wraps with `GestureHandlerRootView` + `ThemeProvider` | `apps/mobile/app/_layout.tsx:204-231` |
| No `BottomSheetModalProvider` at root (PremiumFeatureSheet uses plain `BottomSheet`) | `apps/mobile/app/_layout.tsx` — absent |
| `packages/shared/src/index.ts` exports `auth-gating` but no tokens | `packages/shared/src/index.ts:1-10` |
| `packages/shared/package.json` exports map has no `./tokens` key | `packages/shared/package.json:13-61` |
| AIChatOrb electron bar colors: idle=`rgba(88,86,214,0.70)`, connecting=`rgba(59,130,246,0.80)`, thinking=`rgba(251,191,36,0.80)`, speaking=`rgba(34,197,94,0.80)` | `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx:30-41` |
| tsconfig `@/*` alias maps to `./` (app root) | `apps/mobile/tsconfig.json:6-9` |

---

## 1. New files in `apps/mobile/lib/theme/`

### 1.1 File layout decision

The UI-SPEC §9 prescribes splitting colors, typography, tokens, and the hook into separate files. This is the correct choice — it keeps token modules importable in test environments without pulling in hooks. The hook file imports from the others; tests can import token modules directly without a render context.

```
apps/mobile/lib/theme/
  colors.ts      — colorsLight, colorsDark, ColorTokens type
  typography.ts  — typography const (family, scale, weights, lineHeights)
  tokens.ts      — spacing, radius, motion, shadow (pure numerics)
  useTheme.ts    — useTheme() hook + Theme type
  index.ts       — barrel
```

### 1.2 `apps/mobile/lib/theme/colors.ts`

**Full content to implement:**

```ts
// apps/mobile/lib/theme/colors.ts
// Semantic color tokens matching iOS UIKit semantics.
// All rgba values are intentional — they composite correctly on tinted surfaces.

export const colorsLight = {
  background: {
    primary:   '#FFFFFF',
    secondary: '#F2F2F7',
    tertiary:  '#FFFFFF',
    grouped:   '#F2F2F7',
  },
  label: {
    primary:    '#000000',
    secondary:  'rgba(60,60,67,0.60)',
    tertiary:   'rgba(60,60,67,0.30)',
    quaternary: 'rgba(60,60,67,0.18)',
  },
  fill: {
    primary:    'rgba(120,120,128,0.20)',
    secondary:  'rgba(120,120,128,0.16)',
    tertiary:   'rgba(118,118,128,0.12)',
    quaternary: 'rgba(116,116,128,0.08)',
  },
  separator: {
    opaque:    '#C6C6C8',
    nonOpaque: 'rgba(60,60,67,0.29)',
  },
  accent: {
    primary: '#0a7ea4',
    success: '#34C759',
    warning: '#FF9F0A',
    error:   '#FF3B30',
  },
  reader: {
    paper:          '#FAF8F3',
    ink:            '#1C1C1E',
    paperPureWhite: '#FFFFFF',
    paperSepia:     '#F6F0E2',
  },
  highlight: {
    yellow: 'rgba(255,224,102,0.45)',
    green:  'rgba(143,225,158,0.45)',
    blue:   'rgba(143,196,255,0.45)',
    pink:   'rgba(255,170,200,0.45)',
    purple: 'rgba(204,178,242,0.45)',
  },
} as const;

export const colorsDark = {
  background: {
    primary:   '#000000',
    secondary: '#1C1C1E',
    tertiary:  '#2C2C2E',
    grouped:   '#000000',
  },
  label: {
    primary:    '#FFFFFF',
    secondary:  'rgba(235,235,245,0.60)',
    tertiary:   'rgba(235,235,245,0.30)',
    quaternary: 'rgba(235,235,245,0.18)',
  },
  fill: {
    primary:    'rgba(120,120,128,0.36)',
    secondary:  'rgba(120,120,128,0.32)',
    tertiary:   'rgba(118,118,128,0.24)',
    quaternary: 'rgba(118,118,128,0.18)',
  },
  separator: {
    opaque:    '#38383A',
    nonOpaque: 'rgba(84,84,88,0.65)',
  },
  accent: {
    primary: '#3AB4D6',
    success: '#30D158',
    warning: '#FF9F0A',
    error:   '#FF453A',
  },
  reader: {
    paper:          '#000000',
    ink:            '#B8B8B9',
    paperPureWhite: '#FFFFFF',
    paperSepia:     '#F6F0E2',
  },
  highlight: {
    yellow: 'rgba(255,224,102,0.32)',
    green:  'rgba(143,225,158,0.32)',
    blue:   'rgba(143,196,255,0.32)',
    pink:   'rgba(255,170,200,0.32)',
    purple: 'rgba(204,178,242,0.32)',
  },
} as const;

/** Structural type for both palettes — derived from light (canonical shape). */
export type ColorTokens = typeof colorsLight;
```

### 1.3 `apps/mobile/lib/theme/typography.ts`

```ts
// apps/mobile/lib/theme/typography.ts
import { Platform } from 'react-native';

export const typography = {
  family: Platform.select({
    ios: {
      sans:    'system-ui',
      serif:   'ui-serif',
      rounded: 'ui-rounded',
      mono:    'ui-monospace',
    },
    default: {
      sans:    'normal',
      serif:   'serif',
      rounded: 'normal',
      mono:    'monospace',
    },
    web: {
      sans:    "system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      serif:   "Georgia, 'Times New Roman', serif",
      rounded: "'SF Pro Rounded', sans-serif",
      mono:    "SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    },
  })!,
  weights: {
    regular:  '400',
    medium:   '500',
    semibold: '600',
    bold:     '700',
  } as const,
  lineHeights: {
    tight:   1.2,
    normal:  1.4,
    relaxed: 1.5,
  } as const,
  scale: {
    'display-large': { fontSize: 34, fontWeight: '600' as const, lineHeight: 41,   family: 'sans' as const },
    'display':       { fontSize: 28, fontWeight: '600' as const, lineHeight: 34,   family: 'sans' as const },
    'title':         { fontSize: 22, fontWeight: '600' as const, lineHeight: 28,   family: 'sans' as const },
    'body':          { fontSize: 17, fontWeight: '400' as const, lineHeight: 22,   family: 'sans' as const },
    'callout':       { fontSize: 16, fontWeight: '400' as const, lineHeight: 21,   family: 'sans' as const },
    'subhead':       { fontSize: 15, fontWeight: '400' as const, lineHeight: 20,   family: 'sans' as const },
    'footnote':      { fontSize: 13, fontWeight: '400' as const, lineHeight: 18,   family: 'sans' as const },
    'caption':       { fontSize: 12, fontWeight: '400' as const, lineHeight: 16,   family: 'sans' as const },
    'caption-small': { fontSize: 11, fontWeight: '400' as const, lineHeight: 13,   family: 'sans' as const },
    'reader-body':   { fontSize: 17, fontWeight: '400' as const, lineHeight: 25.5, family: 'serif' as const },
  },
} as const;

export type Typography = typeof typography;
export type TypographyScaleKey = keyof typeof typography.scale;
```

### 1.4 `apps/mobile/lib/theme/tokens.ts`

```ts
// apps/mobile/lib/theme/tokens.ts
// Pure numeric/structural tokens. No colors, no Platform imports.

export const spacing = {
  none: 0,
  xxs:  2,
  xs:   4,
  sm:   8,
  md:   12,
  lg:   16,
  xl:   20,
  '2xl': 24,
  '3xl': 32,
  '4xl': 40,
  '5xl': 56,
  '6xl': 80,
} as const;

export const radius = {
  none: 0,
  sm:   6,
  md:   10,
  lg:   14,
  xl:   20,
  full: 9999,
} as const;

export const motion = {
  spring: {
    // Raw Reanimated coefficients — hand-tuned to match Apple Books feel.
    // Do NOT algebra-convert to damping ratios; use these numbers directly.
    gentle: { damping: 18, stiffness: 250, mass: 1 },
    snappy: { damping: 22, stiffness: 400, mass: 1 },
    bouncy: { damping: 12, stiffness: 200, mass: 1 },
  },
  timing: {
    fast:   { duration: 200 },
    normal: { duration: 300 },
    slow:   { duration: 500 },
  },
} as const;

export const shadow = {
  flat: {
    shadowColor:   '#000',
    shadowOpacity: 0,
    shadowRadius:  0,
    shadowOffset:  { width: 0, height: 0 },
    elevation:     0,
  },
  low: {
    shadowColor:   '#000',
    shadowOpacity: 0.06,
    shadowRadius:  2,
    shadowOffset:  { width: 0, height: 1 },
    elevation:     1,
  },
  medium: {
    shadowColor:   '#000',
    shadowOpacity: 0.12,
    shadowRadius:  14,
    shadowOffset:  { width: 0, height: 6 },
    elevation:     8,
  },
  high: {
    shadowColor:   '#000',
    shadowOpacity: 0.18,
    shadowRadius:  28,
    shadowOffset:  { width: 0, height: 12 },
    elevation:     16,
  },
} as const;

export type Spacing  = typeof spacing;
export type Radius   = typeof radius;
export type Motion   = typeof motion;
export type Shadow   = typeof shadow;
export type SpacingKey = keyof Spacing;
export type RadiusKey  = keyof Radius;
```

### 1.5 `apps/mobile/lib/theme/useTheme.ts`

```ts
// apps/mobile/lib/theme/useTheme.ts
import { useColorScheme, AccessibilityInfo } from 'react-native';
import { useEffect, useState, useMemo } from 'react';
import { colorsLight, colorsDark, type ColorTokens } from './colors';
import { typography, type Typography } from './typography';
import { spacing, radius, motion, shadow, type Spacing, type Radius, type Motion, type Shadow } from './tokens';

export type Theme = {
  scheme: 'light' | 'dark';
  colors: ColorTokens;
  typography: Typography;
  spacing: Spacing;
  radius: Radius;
  motion: Motion;
  shadow: Shadow;
  reduceMotion: boolean;
};

export function useTheme(): Theme {
  const systemScheme = useColorScheme() ?? 'light';
  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void AccessibilityInfo.isReduceMotionEnabled().then((v) => {
      if (!cancelled) setReduceMotion(v);
    });
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => {
      cancelled = true;
      sub.remove();
    };
  }, []);

  return useMemo(() => ({
    scheme:       systemScheme,
    colors:       systemScheme === 'dark' ? colorsDark : colorsLight,
    typography,
    spacing,
    radius,
    motion,
    shadow,
    reduceMotion,
  }), [systemScheme, reduceMotion]);
}
```

**Type signatures the tester must verify compile:**
- `useTheme()` return type is `Theme`
- `theme.colors` is `ColorTokens` (same shape whether light or dark — TS narrows via union)
- `theme.spacing['2xl']` is `24` (literal number type)
- `theme.motion.spring.gentle` is `{ readonly damping: 18; readonly stiffness: 250; readonly mass: 1 }`

### 1.6 `apps/mobile/lib/theme/index.ts`

```ts
// apps/mobile/lib/theme/index.ts
export { useTheme, type Theme } from './useTheme';
export { colorsLight, colorsDark, type ColorTokens } from './colors';
export { typography, type Typography, type TypographyScaleKey } from './typography';
export { spacing, radius, motion, shadow, type Spacing, type Radius, type Motion, type Shadow, type SpacingKey, type RadiusKey } from './tokens';
```

---

## 2. New files in `packages/shared/src/tokens/`

### 2.1 Architecture decision: shared orb-colors only

The UI-SPEC §9 confirms: mobile-local tokens for Phase 2. Only the AIChatOrb status-to-color map goes into `packages/shared` because Phase 4 mobile needs the exact same RGBA values as the electron orb (`AIChatOrb.tsx:30-41`).

### 2.2 `packages/shared/src/tokens/orb-colors.ts`

The RGBA values are transcribed verbatim from `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx` lines 30-41:

```ts
// packages/shared/src/tokens/orb-colors.ts
// Canonical AIChatOrb bar colors — shared between electron and mobile Phase 4.
// Source: apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx L30-41

/** Four discrete states of the AI chat orb. */
export type AIChatOrbStatus = 'idle' | 'connecting' | 'thinking' | 'speaking';

/**
 * Map of orb status to CSS/RN-compatible rgba string for the 4 vertical bars.
 * Values are the exact strings from the electron AIChatOrb component.
 */
export const ORB_COLORS: Record<AIChatOrbStatus, string> = {
  idle:       'rgba(88,86,214,0.70)',   // purple
  connecting: 'rgba(59,130,246,0.80)',  // blue
  thinking:   'rgba(251,191,36,0.80)',  // amber
  speaking:   'rgba(34,197,94,0.80)',   // green
} as const;
```

### 2.3 `packages/shared/src/tokens/index.ts`

```ts
// packages/shared/src/tokens/index.ts
export { ORB_COLORS, type AIChatOrbStatus } from './orb-colors';
```

### 2.4 Update `packages/shared/src/index.ts`

Add one line at the end:

```ts
export * from "./tokens/index";
```

Complete file becomes:
```ts
export * from "./schema";
export * from "./sync-types";
export * from "./sync-adapter";
export * from "./sync-engine";
export * from "./types/highlight";
export * from "./types/conversation";
export * from "./types/paragraph";
export * from "./types/pdf-locator";
export * from "./lib/languages";
export * from "./auth-gating/index";
export * from "./tokens/index";   // ← add this line
```

### 2.5 Update `packages/shared/package.json` exports

Add one entry to the `"exports"` map (after the existing `"./auth-gating"` line, before the closing `}`):

```json
"./tokens": "./src/tokens/index.ts"
```

This makes `import { ORB_COLORS } from '@rishi/shared/tokens'` work in all consumers.

---

## 3. New mobile primitives in `apps/mobile/components/ui/`

All primitives use `StyleSheet` + `useTheme()`. NativeWind classes are NOT used inside the new primitives (they use StyleSheet for predictable behavior in test environments). Existing screens that use NativeWind classes are untouched in Phase 2.

**Critical: `BottomSheetModalProvider` is absent from the root layout** (`apps/mobile/app/_layout.tsx`). The existing `PremiumFeatureSheet` uses plain `BottomSheet` (not `BottomSheetModal`). The new `Sheet` primitive must follow the same plain `BottomSheet` pattern rather than the `BottomSheetModal` / provider pattern to avoid requiring a root layout change in Phase 2. If the product wants `BottomSheetModal` in Phase 3, adding `BottomSheetModalProvider` to `_layout.tsx` can happen then.

### 3a. `Sheet.tsx`

**Path:** `apps/mobile/components/ui/Sheet.tsx`

**UI-SPEC reference:** §7a

**Props interface:**
```ts
import type { ReactNode } from 'react';

export type SheetProps = {
  isOpen: boolean;
  onClose: () => void;
  snapPoints?: Array<string | number>;  // default: ['50%']
  enableDynamicSizing?: boolean;        // default: true when snapPoints undefined; false otherwise
  children: ReactNode;
  title?: string;
  accessibilityLabel?: string;          // falls back to title
  showGrabber?: boolean;                // default: true
  scrollable?: boolean;                 // default: false — uses BottomSheetView vs BottomSheetScrollView
};
```

**Implementation strategy:** Wraps `@gorhom/bottom-sheet`'s `BottomSheet` (plain, not Modal). Uses a `useRef<BottomSheet>`. An `useEffect` on `isOpen` calls `sheetRef.current?.expand()` (index 0) when true and `sheetRef.current?.close()` when false. The `onChange` callback: when index reaches `-1`, calls `onClose()`. `backdropComponent` renders `BottomSheetBackdrop` with `pressBehavior="close"`, `appearsOnIndex={0}`, `disappearsOnIndex={-1}`. `handleIndicatorStyle` uses `colors.fill.tertiary` for the grabber pill (not `fill.secondary` — the grabber is quieter than the search bar). `backgroundStyle` uses `colors.background.secondary`. Bottom content padding is computed as `useSafeAreaInsets().bottom + spacing.lg`. Optional title row renders a `Text` with the `title` typography scale style + a `Hairline` below it. Reduce-motion: pass `animationConfigs={{ duration: motion.timing.normal.duration }}` wrapped in `useAnimatedStyle` — for Phase 2, use `BottomSheet`'s `animationConfigs` prop with a `withTiming` object from Reanimated. `accessibilityViewIsModal={true}` on the container.

**States:** open / closed

**Accessibility:** `accessibilityViewIsModal={true}`; VoiceOver announces `accessibilityLabel` (defaults to `title`) when sheet expands.

**Replaces in Phase 3:** All 6 existing reader sheets (`AppearanceSheet`, `TocSheet`, `HighlightsSheet`, `BookmarksList`, `SearchPanel`, `NoteEditor`) which each have inline `backgroundStyle`/`handleIndicatorStyle` and no backdrop. `PremiumFeatureSheet` is already correct and can optionally migrate to use this wrapper.

---

### 3b. `Toolbar.tsx`

**Path:** `apps/mobile/components/ui/Toolbar.tsx`

**UI-SPEC reference:** §7b

**Props interface:**
```ts
import type { ReactNode } from 'react';

export type ToolbarProps = {
  position: 'top' | 'bottom';
  left?: ReactNode;
  center?: ReactNode;
  right?: ReactNode;
  transparent?: boolean;   // default: false
  blur?: boolean;          // default: false (expo-blur not installed; placeholder only)
  hairline?: boolean;      // default: true
  testID?: string;
};
```

**Implementation strategy:** A `View` with `StyleSheet.absoluteFill` background (color: `colors.background.primary` when `transparent=false`; `rgba(255,255,255,0.95)` light / `rgba(0,0,0,0.95)` dark when `transparent=true`). `blur=true` is accepted as a prop but in Phase 2 renders no `BlurView` (expo-blur not installed) — it falls through to the transparent rgba fallback. A `// TODO Phase 3: replace rgba with <BlurView>` comment marks the location. `useSafeAreaInsets()` provides `insets.top` (top position) or `insets.bottom` (bottom position) for padding. The three-slot row uses `flexDirection: 'row'` with the center slot absolutely positioned (`position: 'absolute', left: 0, right: 0, alignItems: 'center'`) so left/right content widths do not push it. Min height `44`. `accessibilityRole="toolbar"` on the outer container. `hairline=true` (default) renders `<Hairline>` at the correct edge: top toolbar gets a bottom hairline; bottom toolbar gets a top hairline.

**States:** default only (layout container)

**Accessibility:** `accessibilityRole="toolbar"`

**Replaces in Phase 3:** `components/ReaderToolbar.tsx` (single-bar, 16 props) is replaced by two `<Toolbar position="top">` + `<Toolbar position="bottom">` instances inside a new `<ReaderShell>` component.

---

### 3c. `IconButton.tsx`

**Path:** `apps/mobile/components/ui/IconButton.tsx`

**UI-SPEC reference:** §7c

**Props interface:**
```ts
import type { Ionicons } from '@expo/vector-icons';

export type HapticVariant = 'selection' | 'soft' | 'medium';

export type IconButtonProps = {
  name: keyof typeof Ionicons.glyphMap;
  onPress: () => void;
  size?: number;           // default: 22
  color?: string;          // default: colors.label.primary
  label: string;           // REQUIRED — VoiceOver label; TS enforces non-optional
  hitSlop?: number | { top: number; bottom: number; left: number; right: number };
  haptic?: HapticVariant;  // default: 'selection'
  disabled?: boolean;      // default: false
  testID?: string;
};
```

**Implementation strategy:** Renders `<PressableScale>` wrapping `<Ionicons name={name} size={size} color={effectiveColor} />`. `effectiveColor` is `disabled ? colors.label.quaternary : (color ?? colors.label.primary)`. On press: fires haptic before calling `onPress` — `selection` → `Haptics.selectionAsync()`, `soft` → `Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)`, `medium` → `Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)`. When `disabled=true`, the onPress no-op is passed to `PressableScale` (`disabled` prop), so the haptic branch is skipped. Default `hitSlop` is `8` on all sides (22pt icon + 8 each side = 38pt; set to 11 on all sides for a strict 44pt target, but the UI-SPEC says 8 with note that callers inflate if needed — use 8 as specified). `accessibilityRole="button"`, `accessibilityLabel={label}`, `accessibilityState={{ disabled: !!disabled }}`.

**States:** default, pressed (scale via `PressableScale`), disabled (quaternary color, no haptic, no scale)

**Accessibility:** `label` is type-required (non-optional string); `accessibilityState={{ disabled }}`

**Replaces in Phase 3:** Inline `TouchableOpacity` + `Ionicons` patterns in `ReaderToolbar` (which has 8+ action icons inline).

---

### 3d. `Hairline.tsx`

**Path:** `apps/mobile/components/ui/Hairline.tsx`

**UI-SPEC reference:** §7d

**Props interface:**
```ts
export type HairlineProps = {
  orientation?: 'horizontal' | 'vertical';  // default: 'horizontal'
  color?: string;                           // default: colors.separator.nonOpaque
  inset?: number;                           // default: 0
};
```

**Implementation strategy:** Pure `<View accessible={false}>` — no interaction, no animation. `StyleSheet.hairlineWidth` is the authoritative 1-physical-pixel value on all screen densities (0.5pt on @3x). Horizontal: `{ height: StyleSheet.hairlineWidth, width: '100%', marginLeft: inset, backgroundColor: color }`. Vertical: `{ width: StyleSheet.hairlineWidth, height: '100%', marginTop: inset, backgroundColor: color }`. The `color` defaults are read from `useTheme()` inside the component; no prop is required.

**States:** none (decorative `accessible={false}`)

**Replaces in Phase 3:** Hardcoded `borderTopWidth: StyleSheet.hairlineWidth` and `borderBottomWidth` inline on reader toolbar containers.

---

### 3e. `PressableScale.tsx`

**Path:** `apps/mobile/components/ui/PressableScale.tsx`

**UI-SPEC reference:** §7e

**Props interface:**
```ts
import type { ViewStyle } from 'react-native';
import type { ReactNode } from 'react';

export type PressableScaleProps = {
  children: ReactNode;
  onPress: () => void;
  onPressIn?: () => void;
  onPressOut?: () => void;
  hitSlop?: number | { top: number; bottom: number; left: number; right: number };
  scale?: number;           // default: 0.95
  disabled?: boolean;       // default: false
  accessibilityLabel: string;  // REQUIRED
  accessibilityRole?: 'button' | 'link' | 'imagebutton' | 'menuitem';  // default: 'button'
  accessibilityHint?: string;
  style?: ViewStyle;
  testID?: string;
};
```

**Implementation strategy:** Uses Reanimated 4's `useSharedValue(1)` for scale, `useAnimatedStyle` for the transform, and `Animated.View` wrapping children. `onPressIn`: `scaleValue.value = withSpring(scale ?? 0.95, motion.spring.snappy)`. `onPressOut`: `scaleValue.value = withSpring(1, motion.spring.snappy)`. Wraps a plain RN `Pressable` (not `TouchableOpacity`) so `onPressIn`/`onPressOut` fire reliably. Reduce-motion: when `reduceMotion` from `useTheme()` is `true`, replace the scale transform with an opacity: `opacityValue.value = withTiming(0.7, motion.timing.fast)` on press-in, `withTiming(1, motion.timing.fast)` on press-out; the scale `useAnimatedStyle` returns `{}` in this mode. Disabled: opacity `0.4`, no animation, `onPress` is a no-op. **Note:** `Pressable` from react-native is used (not the deprecated `TouchableOpacity`) because it provides clean `onPressIn`/`onPressOut` callbacks without gesture conflict.

**States:** default, pressed (scale to `props.scale`), disabled (opacity 0.4)

**Accessibility:** `accessibilityLabel` type-required; `accessibilityRole` defaults to `'button'`

**Replaces in Phase 3:** Various `Pressable` + `style={({ pressed }) => [{ opacity: pressed ? 0.8 : 1 }]}` patterns across reader and library components.

---

### 3f. `BookCover.tsx`

**Path:** `apps/mobile/components/ui/BookCover.tsx`

**UI-SPEC reference:** §7f

**Props interface:**
```ts
import type { RadiusKey } from '@/lib/theme';

export type BookCoverSize = 'sm' | 'md' | 'lg';
export type BookCoverElevation = 'flat' | 'low' | 'medium';

export type BookCoverProps = {
  uri?: string | null;
  title: string;
  size: BookCoverSize;
  aspectRatio?: number;          // default: 2/3
  rounded?: RadiusKey;           // default: 'md'
  elevation?: BookCoverElevation; // default: 'low'
  testID?: string;
};
```

**Implementation strategy:** Width derived from `size`: `sm=48`, `md=96`, `lg=144`. Height = `width / (aspectRatio ?? (2/3))`. The outer `View` receives the shadow token from `useTheme().shadow[elevation]` spread into its style, plus a `borderRadius` from `useTheme().radius[rounded]`. When `uri` is provided: renders `<Image source={{ uri }} style={{ width, height, borderRadius }} contentFit="cover" />` from `expo-image` (already installed at `~3.0.11`). An `onError` handler sets local `hasError` state. Fallback (no `uri` or `hasError === true`): renders a `<View>` with a deterministic background color (hash `title` using `charCodeAt` sum mod 8, map to 8 distinct muted colors; see color table below) and a centered `<Text>` showing `title[0].toUpperCase()` at `typography.scale['display-large'].fontSize` in white. Border: `0.5` width, `colors.separator.nonOpaque` color, wrapping the entire cover (subtle edge on white backgrounds). `accessibilityRole="image"`, `accessibilityLabel={\`Cover of ${title}\`}`.

**Fallback color palette (8 colors, mod-indexed by title char sum):**
```
['#8B7355', '#5B8B6B', '#6B7B8B', '#8B6B7B', '#7B8B5B', '#6B5B8B', '#8B7B5B', '#5B6B8B']
```
These are muted, accessible tones that work in both light and dark mode.

**States:** default (image), error-fallback (letter), no interactive states

**Accessibility:** `accessibilityRole="image"`, `accessibilityLabel` from title

**Replaces in Phase 3:** The inline `Image` + fallback `View` in `BookRow.tsx` (Phase 2 smoke test replaces it immediately). The `Image` + fallback blocks in `app/(tabs)/index.tsx` lines 174-179 (last-read card) and the future grid.

---

### 3g. `SegmentedControl.tsx`

**Path:** `apps/mobile/components/ui/SegmentedControl.tsx`

**UI-SPEC reference:** §7g

**Props interface:**
```ts
export type SegmentedControlOption<T extends string> = {
  label: string;
  value: T;
};

export type SegmentedControlProps<T extends string> = {
  value: T;
  onChange: (next: T) => void;
  options: ReadonlyArray<SegmentedControlOption<T>>;
  fullWidth?: boolean;    // default: false
  size?: 'sm' | 'md';    // default: 'md'
  testID?: string;
};
```

**Implementation strategy:** Outer container has `backgroundColor: colors.fill.primary`, `borderRadius: radius.lg`. Segment width: equal division of total width (`fullWidth=true`) or `minWidth` from `label.length * 8 + spacing.md * 2`. The "pill" highlight is an absolutely-positioned `View` behind the segments with `backgroundColor: colors.background.primary` (light) / `colors.fill.tertiary` (dark), shadow `low`, same `borderRadius`. Pill `translateX` is a Reanimated `useSharedValue` initialized from the selected index. When `value` prop changes, `useEffect` fires `withSpring(newX, motion.spring.snappy)` on the shared value. Each segment is a `Pressable` that on press: calls `Haptics.selectionAsync()` then `onChange(option.value)`. Height: `size='md'` → 36pt, `size='sm'` → 28pt. Font: `size='md'` → subhead semibold, `size='sm'` → footnote. `accessibilityRole="tablist"` on container; each segment is `accessibilityRole="tab"`, `accessibilityState={{ selected: option.value === value }}`.

**States:** per-segment: default, selected (pill behind), pressed (opacity 0.7)

**Accessibility:** Full ARIA tab pattern

**Replaces in Phase 3:** The appearance sheet font/theme picker will use this. Phase 2 creates it only; no existing component uses it until Phase 3.

---

### 3h. `SearchBar.tsx`

**Path:** `apps/mobile/components/ui/SearchBar.tsx`

**UI-SPEC reference:** §7h

**Props interface:**
```ts
export type SearchBarProps = {
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;   // default: 'Search'
  onClear?: () => void;   // if undefined, internal handler sets value to ''
  onCancel?: () => void;  // if provided, Cancel button shown on focus
  onSubmit?: () => void;
  autoFocus?: boolean;
  testID?: string;
};
```

**Implementation strategy:** Outer container is a `View` row. Inner bar has `backgroundColor: colors.fill.secondary`, `borderRadius: radius.lg`, height 36, horizontal padding `spacing.md`. Leading Ionicons `search` icon (16pt, `colors.label.tertiary`). `TextInput` with `placeholderTextColor: colors.label.tertiary`, `returnKeyType="search"`. Trailing clear `IconButton` (Ionicons `close-circle`, 16pt) visible only when `value.length > 0`. When `onCancel` is provided: a "Cancel" `PressableScale` slides in from the right on focus using a Reanimated `useSharedValue` width animation (`withTiming`, `motion.timing.normal`); on blur or cancel press it retracts. The container width shrinks to make room for the Cancel button (`flex: 1` on the bar). `TextInput accessibilityLabel="Search"`. Cancel is `PressableScale accessibilityLabel="Cancel"`. Clear is `IconButton label="Clear search"`.

**States:** empty, typing, focused-with-cancel, blurred

**Accessibility:** See above

**Replaces in Phase 3:** The bespoke `TextInput` inside `View` search bar in `app/(tabs)/index.tsx` lines 153-167 (which lacks the Cancel animation and uses NativeWind classes).

---

### 3i. `ListRow.tsx`

**Path:** `apps/mobile/components/ui/ListRow.tsx`

**UI-SPEC reference:** §7i

**Props interface:**
```ts
import type { ReactNode } from 'react';
import { Switch } from 'react-native';

export type ListRowAccessory =
  | 'chevron'
  | 'check'
  | { kind: 'switch'; value: boolean; onValueChange: (next: boolean) => void }
  | { kind: 'custom'; node: ReactNode };

export type ListRowProps = {
  icon?: ReactNode;          // typically <Ionicons /> 22pt
  title: string;
  subtitle?: string;
  accessory?: ListRowAccessory;
  value?: string;            // right-aligned text e.g. "Off", "1.2 MB"
  onPress?: () => void;      // omit for non-interactive row
  destructive?: boolean;     // default: false
  testID?: string;
};
```

**Implementation strategy:** Min height 44pt, vertical padding `spacing.sm`, horizontal padding `spacing.lg`. Layout: `flexDirection: 'row'`, `alignItems: 'center'`. Leading icon slot (if present, 22pt wide with `spacing.sm` right margin). Title/subtitle column (`flex: 1`): title in `body` typography, `colors.label.primary` (or `colors.accent.error` when `destructive`); subtitle in `subhead`, `colors.label.secondary`. Value text at right: `subhead`, `colors.label.secondary`, `marginRight: spacing.sm`. Accessory: `chevron` = Ionicons `chevron-forward` 16pt `colors.label.tertiary`; `check` = Ionicons `checkmark` 20pt `colors.accent.primary`; `switch` = `<Switch trackColor={{ true: colors.accent.primary }} thumbColor="#FFFFFF" />`; `custom` = rendered node. If `onPress` provided: wraps in `PressableScale` with `scale=0.99` and fires `Haptics.selectionAsync()`. Bottom hairline is NOT rendered by `ListRow` — callers insert `<Hairline inset={icon ? 56 : 16} />` between rows (matches Apple's inset separator pattern). Non-interactive rows (no `onPress`): plain `View`.

**States:** default, pressed (scale 0.99), no explicit disabled (caller manages)

**Accessibility:** Pressable: `accessibilityRole="button"`, `accessibilityLabel={title}`, `accessibilityHint={subtitle}`. Switch rows: container `accessible={false}`. Destructive: append `, destructive action` to label.

**Replaces in Phase 3:** TOC entries, highlight list rows, bookmarks rows, appearance options.

---

### 3j. `EmptyState.tsx`

**Path:** `apps/mobile/components/ui/EmptyState.tsx`

**UI-SPEC reference:** §7j

**Props interface:**
```ts
import type { ReactNode } from 'react';
import type { Ionicons } from '@expo/vector-icons';

export type EmptyStateProps = {
  icon: keyof typeof Ionicons.glyphMap | ReactNode;
  title: string;
  description?: string;
  action?: { label: string; onPress: () => void };
  testID?: string;
};
```

**Implementation strategy:** Centered `<View>` with `alignItems: 'center'`, `paddingHorizontal: spacing['2xl']`, `paddingTop: spacing['5xl']`. `spacing.xl` gap between elements (`marginBottom: spacing.xl` on each child). Icon: if `typeof icon === 'string'` render `<Ionicons name={icon} size={56} color={colors.label.tertiary} />` (decorative, no accessibility role); if `ReactNode` render as-is. Title: `typography.scale.title`, `colors.label.primary`, `textAlign: 'center'`. Description: `typography.scale.body`, `colors.label.secondary`, `textAlign: 'center'`, `maxWidth: 320`. Action button: `PressableScale` wrapping a `View` with `height: 44`, `borderRadius: radius.full`, `backgroundColor: colors.accent.primary`, centered `Text` in `body` semibold white. Haptic on press: `Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium)`.

**States:** default; action: default / pressed / disabled

**Accessibility:** Container `accessibilityRole="summary"`. Action `accessibilityRole="button"` via `PressableScale`.

**Replaces in Phase 3 (and smoke test in Phase 2):** `components/LibraryEmptyState.tsx` (currently hardcodes colors, font sizes, NativeWind classes). The `LibraryEmptyState` will delegate to `EmptyState` in Phase 3; Phase 2 does not touch it.

---

### 3k. `apps/mobile/components/ui/index.ts`

```ts
// apps/mobile/components/ui/index.ts
export { Sheet, type SheetProps } from './Sheet';
export { Toolbar, type ToolbarProps } from './Toolbar';
export { IconButton, type IconButtonProps, type HapticVariant } from './IconButton';
export { Hairline, type HairlineProps } from './Hairline';
export { PressableScale, type PressableScaleProps } from './PressableScale';
export { BookCover, type BookCoverProps, type BookCoverSize, type BookCoverElevation } from './BookCover';
export { SegmentedControl, type SegmentedControlProps, type SegmentedControlOption } from './SegmentedControl';
export { SearchBar, type SearchBarProps } from './SearchBar';
export { ListRow, type ListRowProps, type ListRowAccessory } from './ListRow';
export { EmptyState, type EmptyStateProps } from './EmptyState';
// Re-export existing primitive unchanged
export { IconSymbol } from './icon-symbol';
```

---

## 4. Existing files to modify in Phase 2

### 4.1 `apps/mobile/constants/theme.ts` — no change

Decision: **leave `constants/theme.ts` completely untouched.** The new `lib/theme/` module is fully independent. `use-theme-color.ts` shim (§4.2) bridges old callers. Deleting or re-exporting from `constants/theme.ts` in Phase 2 risks breaking `(tabs)/_layout.tsx:53` (`Colors[colorScheme ?? 'light'].tint`) and `themed-text.tsx:18` without upside. Rationale: the shim achieves back-compat without touching the constants file.

### 4.2 `apps/mobile/hooks/use-theme-color.ts` — thin shim

Replace the file body to delegate to `useTheme()` for new color lookups while preserving the existing `colorName` parameter contract for old callers. The existing callers only pass `colorName` values from `keyof typeof Colors.light` — those 6 keys (`text`, `background`, `tint`, `icon`, `tabIconDefault`, `tabIconSelected`) are not in the new semantic token tree, so the shim must bridge them.

```ts
/**
 * @deprecated Use `useTheme().colors` from `@/lib/theme` for new code.
 * This shim keeps existing callers working during the Phase 2→3 migration.
 */
import { Colors } from '@/constants/theme';
import { useColorScheme } from '@/hooks/use-color-scheme';

export function useThemeColor(
  props: { light?: string; dark?: string },
  colorName: keyof typeof Colors.light & keyof typeof Colors.dark,
): string {
  const theme = useColorScheme() ?? 'light';
  const colorFromProps = props[theme];
  if (colorFromProps) {
    return colorFromProps;
  }
  return Colors[theme][colorName];
}
```

This is functionally identical to the existing implementation — the only change is the `@deprecated` JSDoc. No caller changes needed.

### 4.3 `apps/mobile/components/BookRow.tsx` — smoke test refactor

Replace the inline `Image` + fallback `View` cover block with `<BookCover>`. Keep all existing props, behavior, and testIDs. The `PressableScale` wrapper is NOT added here — the outer `Pressable` stays, since `BookRow` has its own delete button that must stay untouched.

Key change:
```
// BEFORE (lines 23-41):
{book.coverPath ? (
  <Image source={{ uri: book.coverPath }} className="w-12 h-16 rounded-md mr-4" resizeMode="cover" />
) : (
  <View className={`w-12 h-16 ...`}>
    <Text className="...">{book.format.toUpperCase()}</Text>
  </View>
)}

// AFTER:
<BookCover uri={book.coverPath} title={book.title} size="sm" style={{ marginRight: spacing.lg }} />
```

The `ListRow` is NOT used here in Phase 2 because `BookRow` has a delete button on the right that `ListRow`'s `accessory` type does not support (delete is an action, not a chevron/check/switch/custom accessory in the same semantic sense). The `ListRow` migration is Phase 3 work — this Phase 2 smoke test only validates `BookCover` in a real render tree.

Also add `style` as a passthrough prop to `BookCover` (not in the main interface, but as an optional `style?: ViewStyle` for spacing). Actually simpler: wrap `<BookCover>` in a `<View style={{ marginRight: spacing.lg }}>`.

### 4.4 `apps/mobile/app/(tabs)/index.tsx` — last-read card smoke test

Replace the `lastReadBook` card cover block (lines 174-179 and 176-178) with `<BookCover>`:

```
// BEFORE:
{lastReadBook.coverPath ? (
  <Image source={{ uri: lastReadBook.coverPath }} className="w-10 h-14 rounded mr-3" resizeMode="cover" />
) : (
  <View className="w-10 h-14 rounded mr-3 bg-gray-200 dark:bg-gray-700 items-center justify-center">
    <Text className="text-gray-400 text-xs">{lastReadBook.format.toUpperCase()}</Text>
  </View>
)}

// AFTER:
<BookCover uri={lastReadBook.coverPath} title={lastReadBook.title} size="sm" />
// wrap in View style={{ marginRight: spacing.md }} for the mr-3 equivalent
```

No other changes to this file. The grid `<BookRow>` items already pick up the `BookCover` change from §4.3.

---

## 5. New dependencies

### 5.1 `expo-blur` — Decision: ADD to `package.json` now, defer `app.json` plugin until Phase 3

**Rationale:** `expo-blur` for RN requires a native rebuild when added as an Expo plugin. However, adding it to `package.json` now without the `app.json` plugin entry means the JS module is available for import but the native `BlurView` silently renders nothing on a pre-built binary. This is exactly what we want: `Toolbar.tsx` conditionally renders a `BlurView` only when `blur=true`, and Phase 2's `blur=true` path uses the rgba fallback anyway (via the `// TODO Phase 3` branch). When Phase 3 adds the plugin to `app.json` and triggers a new EAS build, the `BlurView` renders natively.

**Action for coder:** Add `"expo-blur": "~14.1.4"` to `apps/mobile/package.json` dependencies. The `14.x` series is compatible with Expo SDK 54 (the current version per `package.json:27` `"expo": "~54.0.33"`). Do NOT add `"expo-blur"` to the `plugins` array in `app.json` — that is Phase 3 work.

**Note:** `expo-blur` does NOT require an `app.json` plugin entry just to install — the plugin is optional and only needed to configure native blur capabilities per the Expo docs. The `BlurView` component can be imported without the plugin; on a simulator without the plugin configured it renders a transparent view. This is acceptable for Phase 2 since the Toolbar falls back to rgba anyway.

### 5.2 `expo-image` — already installed

`expo-image@~3.0.11` is present at `apps/mobile/package.json:37`. `BookCover.tsx` imports from `expo-image`. No action needed.

### 5.3 Confirm all other required packages present

| Package | Status |
|---|---|
| `react-native-reanimated@~4.1.1` | Present `package.json:63` |
| `expo-haptics@~15.0.8` | Present `package.json:32` |
| `@gorhom/bottom-sheet@^5.2.8` | Present `package.json:18` |
| `@expo/vector-icons@^15.0.3` | Present `package.json:17` |
| `react-native-safe-area-context@~5.6.0` | Present `package.json:64` |
| `react-native-gesture-handler@~2.28.0` | Present `package.json:60` |
| `expo-image@~3.0.11` | Present `package.json:37` |

---

## 6. Test surface

### 6.1 Test runner configuration note

Mobile tests run via Jest with `@testing-library/react-native`. `react-native-safe-area-context` must be mocked in test setup because it requires native code. The existing test in `apps/mobile/__tests__/sync/file-sync.test.ts` shows the pattern of mocking native modules with `jest.mock()`. For component tests, mock `react-native-safe-area-context` at the test file level or in Jest's `setupFilesAfterFramework` (`moduleNameMapper` or `jest.mock`). Recommended mock for `useSafeAreaInsets`:
```ts
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaView: ({ children }: { children: React.ReactNode }) => children,
}));
```

`@gorhom/bottom-sheet` must similarly be mocked in tests (it requires gesture handler native). Use:
```ts
jest.mock('@gorhom/bottom-sheet', () => {
  const BottomSheet = ({ children, onChange }: any) => {
    // expose expand/close via ref imperatively — simplified test double
    return children;
  };
  BottomSheet.displayName = 'BottomSheet';
  return {
    __esModule: true,
    default: BottomSheet,
    BottomSheetView: ({ children }: any) => children,
    BottomSheetBackdrop: () => null,
  };
});
```

`react-native-reanimated` is already configured for Jest via the Reanimated babel plugin — confirm `babel.config.js` includes it (standard Expo setup).

### 6.2 Shared package tests

**File:** `packages/shared/src/tokens/__tests__/orb-colors.test.ts`

Framework: vitest (existing in `packages/shared`).

Tests:
1. All 4 status keys present: `['idle', 'connecting', 'thinking', 'speaking'].forEach(k => expect(ORB_COLORS).toHaveProperty(k))`
2. All values are non-empty strings: each value matches `/^rgba\(\d/`
3. Type check: `AIChatOrbStatus` type includes exactly the 4 keys (TS compile-time — no runtime assertion needed; covered by the `Record<AIChatOrbStatus, string>` type)

### 6.3 Mobile theme module tests

**File:** `apps/mobile/__tests__/lib/theme/tokens.test.ts`

Tests:
1. Light palette has all required top-level keys: `['background', 'label', 'fill', 'separator', 'accent', 'reader', 'highlight']`
2. Dark palette mirrors light shape: `Object.keys(colorsDark)` deep-equal `Object.keys(colorsLight)`
3. Spacing is strictly monotonic: `Object.values(spacing)` sorted ascending equals `Object.values(spacing)` (no duplicates, no reversals)
4. Radius `full` is 9999
5. Motion spring configs have `damping`, `stiffness`, `mass` keys
6. Shadow `low` has `shadowOpacity` of `0.06`

**File:** `apps/mobile/__tests__/lib/theme/useTheme.test.ts`

Mock `useColorScheme` and `AccessibilityInfo`. Framework: Jest + RNTL.

Tests:
1. Default scheme `'light'` returns `colorsLight` palette (verify `theme.colors.accent.primary === '#0a7ea4'`)
2. Scheme `'dark'` returns `colorsDark` palette (verify `theme.colors.accent.primary === '#3AB4D6'`)
3. `reduceMotion` starts `false`
4. `AccessibilityInfo.addEventListener('reduceMotionChanged', cb)` — simulate firing with `true` → `reduceMotion` becomes `true`
5. Hook returns stable reference across identical inputs (memoization): render twice with same scheme, confirm `===` reference equality of returned object

### 6.4 Component tests

**File:** `apps/mobile/__tests__/components/ui/Sheet.test.tsx`

Mock: `@gorhom/bottom-sheet`, `react-native-safe-area-context`, `expo-haptics`

Tests:
1. `isOpen=false`: sheet does not call `expand()` on mount
2. `isOpen=true`: `sheetRef.expand()` called after render
3. `onClose` called when `onChange` receives index `-1`
4. Backdrop tap: pressing backdrop calls `onClose` (simulate via backdrop `pressBehavior`)
5. Title renders when `title` prop provided

**File:** `apps/mobile/__tests__/components/ui/IconButton.test.tsx`

Mock: `expo-haptics`, `@expo/vector-icons` (render null or a `<View testID="icon">`)

Tests:
1. Fires `onPress` when pressed
2. Does NOT fire `onPress` when `disabled=true`
3. `Haptics.selectionAsync()` called on press (default haptic)
4. `Haptics.impactAsync(Soft)` called when `haptic='soft'`
5. No haptic call when `disabled=true`
6. `accessibilityLabel` matches `label` prop
7. `hitSlop` prop passes through (render, assert style)

**File:** `apps/mobile/__tests__/components/ui/Hairline.test.tsx`

Tests:
1. `height` equals `StyleSheet.hairlineWidth` (horizontal orientation)
2. Default color resolves to a non-null string (color from theme)
3. `accessible={false}` on rendered view

**File:** `apps/mobile/__tests__/components/ui/PressableScale.test.tsx`

Mock: `react-native-reanimated` (use the official Jest mock from `react-native-reanimated/mock`)

Tests:
1. `onPress` fires on press
2. `scaleValue` reaches `0.95` after `pressIn` event (inspect shared value via Reanimated test utils or mock)
3. `scaleValue` returns to `1` after `pressOut`
4. `disabled=true`: `onPress` not called; opacity is `0.4`
5. `accessibilityRole` defaults to `'button'`

**File:** `apps/mobile/__tests__/components/ui/BookCover.test.tsx`

Mock: `expo-image` — replace `Image` with a `<View testID="expo-image" />`

Tests:
1. `uri` provided: renders the `expo-image` Image (query by testID or `accessibilityRole="image"`)
2. `uri=null`: renders fallback View with the first letter of `title` uppercased
3. `onError` on Image → fallback renders
4. `accessibilityLabel` is `"Cover of ${title}"`
5. `accessibilityRole="image"` present

**File:** `apps/mobile/__tests__/components/ui/SegmentedControl.test.tsx`

Mock: `expo-haptics`, `react-native-reanimated`

Tests:
1. Renders all option labels
2. `onChange` fires with the new value when a non-selected segment is pressed
3. `Haptics.selectionAsync()` called on segment press
4. Selected segment has `accessibilityState={{ selected: true }}`
5. Non-selected segment has `accessibilityState={{ selected: false }}`

**File:** `apps/mobile/__tests__/components/ui/ListRow.test.tsx`

Tests:
1. Renders `title`
2. Renders `subtitle` when provided
3. `accessory='chevron'`: Ionicons chevron-forward present
4. `accessory='check'`: Ionicons checkmark present
5. `onPress` fires when pressed (via `PressableScale`)
6. No press handler when `onPress` omitted (renders as plain View — assert not pressable)
7. `destructive=true`: title color is `accent.error`

### 6.5 Deferred test rationale

**`SearchBar.test.tsx`**: The cancel animation requires focus events and animated layout, which are poorly supported in Jest's RNTL environment (layout animations need a native renderer). Defer to Phase 3 where it can be tested in a full Detox E2E scenario alongside the library search flow.

**`EmptyState.test.tsx`**: Best tested in context when `LibraryEmptyState` is migrated to use it (Phase 3). The component is simple enough that a visual regression test via screenshot-critic is more valuable than a unit test.

**`Toolbar.test.tsx`**: The blur/safe-area behavior is simulator-only. Phase 3 Detox test covers it in the reader screen context. Unit-testable only for basic slot rendering — add if coder wants, but not required for Phase 2 green gate.

---

## 7. Build sequence

### Stage A: Shared tokens

```
[ ] Create packages/shared/src/tokens/orb-colors.ts
[ ] Create packages/shared/src/tokens/index.ts
[ ] Append `export * from "./tokens/index"` to packages/shared/src/index.ts
[ ] Add `"./tokens": "./src/tokens/index.ts"` to packages/shared/package.json exports map
[ ] Create packages/shared/src/tokens/__tests__/orb-colors.test.ts
[ ] Run: pnpm -C packages/shared test
[ ] Run: pnpm -C apps/rishi-electron typecheck
[ ] Commit: feat(shared): tokens package — orb-colors type and ORB_COLORS map
```

### Stage B: Mobile theme module

```
[ ] Create apps/mobile/lib/theme/colors.ts (full light + dark palette)
[ ] Create apps/mobile/lib/theme/typography.ts (family, weights, lineHeights, scale)
[ ] Create apps/mobile/lib/theme/tokens.ts (spacing, radius, motion, shadow)
[ ] Create apps/mobile/lib/theme/useTheme.ts (hook + Theme type)
[ ] Create apps/mobile/lib/theme/index.ts (barrel)
[ ] Replace apps/mobile/hooks/use-theme-color.ts with thin shim (add @deprecated JSDoc only; logic unchanged)
[ ] Create apps/mobile/__tests__/lib/theme/tokens.test.ts
[ ] Create apps/mobile/__tests__/lib/theme/useTheme.test.ts
[ ] Run: pnpm -C apps/mobile test
[ ] Commit: feat(mobile): lib/theme — color, typography, token and useTheme hook
```

### Stage C: Mobile primitives

```
[ ] Create apps/mobile/components/ui/PressableScale.tsx  ← implement first; others depend on it
[ ] Create apps/mobile/components/ui/Hairline.tsx
[ ] Create apps/mobile/components/ui/IconButton.tsx      ← depends on PressableScale
[ ] Create apps/mobile/components/ui/BookCover.tsx
[ ] Create apps/mobile/components/ui/Sheet.tsx
[ ] Create apps/mobile/components/ui/Toolbar.tsx         ← depends on Hairline
[ ] Create apps/mobile/components/ui/SegmentedControl.tsx
[ ] Create apps/mobile/components/ui/SearchBar.tsx       ← depends on IconButton
[ ] Create apps/mobile/components/ui/ListRow.tsx         ← depends on PressableScale, Hairline
[ ] Create apps/mobile/components/ui/EmptyState.tsx      ← depends on PressableScale
[ ] Update apps/mobile/components/ui/index.ts (add all new exports)
[ ] Add "expo-blur": "~14.1.4" to apps/mobile/package.json dependencies
[ ] Run: pnpm install (from monorepo root or apps/mobile)
[ ] Create apps/mobile/__tests__/components/ui/Sheet.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/IconButton.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/Hairline.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/PressableScale.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/BookCover.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/SegmentedControl.test.tsx
[ ] Create apps/mobile/__tests__/components/ui/ListRow.test.tsx
[ ] Run: pnpm -C apps/mobile test
[ ] Commit: feat(mobile): design-system primitives (10 components)
```

### Stage D: Smoke-test migration

```
[ ] Refactor apps/mobile/components/BookRow.tsx — replace cover block with <BookCover size="sm">
[ ] Refactor apps/mobile/app/(tabs)/index.tsx — replace lastReadBook cover block with <BookCover size="sm">
[ ] Run: pnpm -C apps/mobile test (existing BookRow tests must still pass)
[ ] Commit: refactor(mobile): BookRow and library screen use BookCover primitive
```

---

## 8. Risks verified

### C1 — `ReaderToolbar` single-bar API incompatible with Phase 3 split

**Verified:** `ReaderToolbar.tsx` is NOT modified in Phase 2. The new `Toolbar` primitive is created alongside it. During Phase 3, `ReaderShell` will render `<Toolbar position="top">` + `<Toolbar position="bottom">` and the existing `ReaderToolbar` will be deleted. During Phase 2→3 transition, both can coexist because they are separate components. **Risk level: LOW for Phase 2.**

### C2 — NativeWind Tailwind colors vs semantic tokens

**Verified:** `tailwind.config.js` has zero custom tokens (`theme.extend: {}`). New primitives use `StyleSheet` exclusively. Screens that use NativeWind classes (`BookRow.tsx`, `index.tsx`) are partially migrated (cover block only) in Phase 2. The NativeWind preset is still active and processes the remaining classes. There is no color token collision because the new tokens are in JS objects, not Tailwind config. **Risk level: NONE for Phase 2.**

### C3 — `AppearanceSheet` font-size is % (for epub.js), not pt

**Verified:** `AppearanceSheet` is NOT touched in Phase 2 (UI-SPEC §11 explicitly defers it to Phase 3). `reader-body` in `typography.ts` uses pt-sized `fontSize: 17` as a default, but the user-controlled size at runtime is a separate concern handled by the epub WebView CSS injection. No conflict. **Risk level: NONE.**

### C4 — `expo-blur` not installed

**Verified confirmed:** `expo-blur` is absent from `apps/mobile/package.json`. The `app.json` plugins array (lines 323-346) does not include `expo-blur`. Decision: add `expo-blur` to `package.json` only. `Toolbar.tsx` renders rgba fallback when `blur=true` in Phase 2. Phase 3 adds the `app.json` plugin and triggers EAS rebuild. **Risk level: MANAGED. No native rebuild needed in Phase 2.**

**Additional finding:** `expo-blur` does NOT require an `app.json` plugin for installation — the plugin only configures native blur entitlements. The JS module is fully importable without it; `BlurView` simply renders a transparent view on builds where the native module is absent. This confirms the Phase 2 rgba-fallback strategy is safe.

### C5 — 6 reader sheets lack backdrop

**Verified:** RESEARCH §1.4 lists 6 sheets without backdrop. Phase 2 creates `Sheet.tsx` with backdrop by default. Phase 3 migrates each reader sheet. The new `Sheet` primitive's backdrop is opt-in via the component's default `backdropComponent`. **Risk level: NONE for Phase 2. Phase 3 must run Detox regression on each sheet migration.**

### C6 — Reader theme system uses raw hex

**Verified:** `constants/reader-themes.ts` is NOT touched in Phase 2. The `reader.*` tokens in `colors.ts` map to the same values as the existing reader themes (`reader.paperPureWhite = '#FFFFFF'` matches `READER_THEMES.white.background`; `reader.paperSepia = '#F6F0E2'` matches `READER_THEMES.yellow.background`). **Risk level: NONE for Phase 2.**

### C7 — No react-native-skia for Phase 4

**Verified:** `react-native-skia` is absent from `package.json`. Phase 2 does not require it. Phase 4 will evaluate Reanimated worklets first. **Risk level: NONE for Phase 2.**

### New risk: BottomSheetModalProvider absent from root

**Found during verification:** `app/_layout.tsx` does not mount `BottomSheetModalProvider`. The existing `PremiumFeatureSheet` uses plain `BottomSheet` (not `BottomSheetModal`). If the new `Sheet.tsx` used `BottomSheetModal`, it would silently fail at runtime without the provider. **Decision: `Sheet.tsx` must use `BottomSheet` (plain) with the `index={-1}` + `expand()/close()` imperative pattern, matching `PremiumFeatureSheet`. This is mandated by the root layout state.** If Phase 3 wants `BottomSheetModal`, it must also add `BottomSheetModalProvider` to `_layout.tsx` — note it in Phase 3 ARCH.

### New risk: `expo-image` API surface differs from `Image` (react-native)

**Verified:** `expo-image@~3.0.11` is installed. Its `Image` component uses `contentFit` (not `resizeMode`). `BookCover.tsx` must import from `expo-image`, not `react-native`. Tests must mock `expo-image` separately from `react-native`'s `Image`. The mock: `jest.mock('expo-image', () => ({ Image: (props: any) => <View testID="expo-image" {...props} /> }))`.

### New risk: `as const` satisfies constraint on `colorsDark`

TypeScript strict mode: `colorsDark` must be structurally identical to `colorsLight` for the `ColorTokens` type alias to cover both. Both are defined `as const` with the same key tree — verified manually above. If a key is added to one and not the other, the tester's "dark mirrors light" test will catch it. **Risk level: LOW — enforced by test.**

### New risk: `tsconfig.json` path aliases in test files

`tsconfig.json` maps `@/*` to `./`. Jest must also resolve this. Check `jest.config.js` (or `package.json` jest config) for `moduleNameMapper`. If missing, `@/lib/theme` imports in tests will fail with "Cannot find module". The coder must add:
```json
"moduleNameMapper": {
  "^@/(.*)$": "<rootDir>/$1"
}
```
to the Jest config if not already present. Verify before Stage B.

---

## 9. Data flow

```
System color scheme (useColorScheme)
  ↓
useTheme() [apps/mobile/lib/theme/useTheme.ts]
  ↓ resolves
  colors: ColorTokens (colorsLight | colorsDark)
  typography: Typography
  spacing: Spacing
  radius: Radius
  motion: Motion
  shadow: Shadow
  reduceMotion: boolean
  ↓ consumed by
  ├── Sheet.tsx         — backgroundStyle, grabber color, bottom padding, animation config
  ├── Toolbar.tsx       — background color, safe-area padding, blur fallback rgba
  ├── IconButton.tsx    — icon color, disabled color
  ├── Hairline.tsx      — separator color
  ├── PressableScale.tsx — spring config (or timing if reduceMotion)
  ├── BookCover.tsx     — border color, shadow style, radius, fallback letter color
  ├── SegmentedControl.tsx — track fill, pill bg, font size
  ├── SearchBar.tsx     — fill bg, placeholder color, font
  ├── ListRow.tsx       — text colors, switch tint, chevron color
  └── EmptyState.tsx    — icon color, text colors, action button bg

AIChatOrbStatus (Phase 4 caller)
  ↓
ORB_COLORS [packages/shared/src/tokens/orb-colors.ts]
  ↓
  Mobile AIChatOrb (Phase 4) — bar backgroundColor per status
  Electron AIChatOrb (existing) — already uses same values inline (Phase 4 migrates it to shared)
```

---

## 10. Files NOT to create or modify in Phase 2

These are explicitly deferred. The tester and coder must not touch them:

- `apps/mobile/components/ReaderToolbar.tsx`
- `apps/mobile/components/AppearanceSheet.tsx`
- `apps/mobile/components/TocSheet.tsx`
- `apps/mobile/components/HighlightsSheet.tsx`
- `apps/mobile/components/BookmarksList.tsx`
- `apps/mobile/components/SearchPanel.tsx`
- `apps/mobile/components/NoteEditor.tsx`
- `apps/mobile/app/reader/[id].tsx`
- `apps/mobile/app/reader/pdf/[id].tsx`
- `apps/mobile/app/reader/mobi/[id].tsx`
- `apps/mobile/app/reader/djvu/[id].tsx`
- `apps/mobile/app/_layout.tsx` (no `BottomSheetModalProvider` addition in Phase 2)
- `apps/mobile/constants/theme.ts`
- `apps/mobile/constants/reader-themes.ts`
- `apps/mobile/components/LibraryEmptyState.tsx`
- `apps/mobile/components/themed-text.tsx`
- `apps/mobile/components/themed-view.tsx`

---

## 11. Verification gate for Phase 2 completion

All of the following must be green before marking Phase 2 done:

1. `pnpm -C packages/shared test` — orb-colors tests pass
2. `pnpm -C apps/mobile test` — all new theme + component tests pass; no new failures in existing tests
3. `pnpm -C apps/rishi-electron typecheck` — clean (shared index change is additive; no breakage)
4. TypeScript compilation of `apps/mobile` — `pnpm -C apps/mobile tsc --noEmit` clean
5. `BookRow.tsx` renders in Expo Go / simulator without crash (manual verification or screenshot-critic)
6. `app/(tabs)/index.tsx` library screen renders book covers correctly (manual verification)

---

**End of ARCH.md**

---

Here is a summary of the key decisions and file locations for the implementer:

**Files to create:**

- `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/src/tokens/orb-colors.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/src/tokens/index.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/src/tokens/__tests__/orb-colors.test.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/lib/theme/colors.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/lib/theme/typography.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/lib/theme/tokens.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/lib/theme/useTheme.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/lib/theme/index.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/PressableScale.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/Hairline.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/IconButton.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/BookCover.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/Sheet.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/Toolbar.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/SegmentedControl.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/SearchBar.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/ListRow.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/EmptyState.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/lib/theme/tokens.test.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/lib/theme/useTheme.test.ts`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/Sheet.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/IconButton.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/Hairline.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/PressableScale.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/BookCover.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/SegmentedControl.test.tsx`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/ListRow.test.tsx`

**Files to modify:**

- `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/src/index.ts` — append `export * from "./tokens/index"`
- `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/package.json` — add `"./tokens": "./src/tokens/index.ts"` to exports
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/index.ts` — add 10 new exports alongside existing `IconSymbol`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/hooks/use-theme-color.ts` — add `@deprecated` JSDoc (logic unchanged)
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/BookRow.tsx` — replace cover block with `<BookCover size="sm">`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/app/(tabs)/index.tsx` — replace `lastReadBook` cover block with `<BookCover size="sm">`
- `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/package.json` — add `"expo-blur": "~14.1.4"`

**Files NOT to touch in Phase 2** (see section 10 for full list, enforced by the tester).
