# Phase 2 — Mobile Design System Foundation (UI-SPEC)

Date: 2026-05-22
Status: Designer spec — input for the architect's file plan
Scope: Tokens, primitives, motion vocabulary. Phase 3 (reader UI) applies these; Phase 2 only creates them.

Design philosophy: Apple Books. Restrained chrome, hairline dividers, generous margins, serif for book content, springy-but-quiet motion, soft haptics, bottom sheets for everything secondary.

Existing conventions (verified):
- `apps/mobile/constants/theme.ts` exposes `Colors.light/dark` + `Fonts` (Platform.select with `system-ui`, `ui-serif`, `ui-rounded`, `ui-monospace`). Brand tint is `#0a7ea4`.
- `apps/mobile/hooks/use-theme-color.ts` reads `useColorScheme()` and indexes into `Colors`.
- `apps/mobile/components/themed-text.tsx` uses literal `fontSize`/`fontWeight` per `type`.
- Bottom sheets via `@gorhom/bottom-sheet@^5`. Haptics via `expo-haptics`. Animation via `react-native-reanimated@~4.1`. Icons via `@expo/vector-icons` (Ionicons).
- Nativewind is installed but unused in most chrome — we stay with `StyleSheet` + `useTheme()` for tokens (Nativewind can wrap later if desired; not required by this spec).

Net-new dep proposed: **`expo-blur`** (Expo-managed, ~30 KB, native iOS UIBlurEffect). Required for the Apple-Books "glass" toolbar (Section 6). Justification: replicating saturate-180/blur-20 with JS is impossible on RN — UIBlurEffect is the only path. Single small dep, no transitive bloat.

---

## 1. Color tokens

Two complete palettes. Hex (or rgba where opacity is meaningful) mirrors iOS UIKit semantic colors. All non-opaque labels/separators/fills are intentionally rgba so they composit correctly on tinted surfaces. Tokens are flat (`background.primary`, not nested objects in token JSON — flat keys make TS narrowing trivial).

### 1.1 Light palette

| Token | Value | Description |
|---|---|---|
| `background.primary` | `#FFFFFF` | App canvas, reader paper-when-pure-white |
| `background.secondary` | `#F2F2F7` | Grouped lists, sheet body |
| `background.tertiary` | `#FFFFFF` | Elevated cells inside grouped lists |
| `background.grouped` | `#F2F2F7` | iOS systemGroupedBackground equivalent |
| `label.primary` | `#000000` | Primary text |
| `label.secondary` | `rgba(60,60,67,0.60)` | Secondary text (captions, subtitles) |
| `label.tertiary` | `rgba(60,60,67,0.30)` | Placeholder, tertiary info |
| `label.quaternary` | `rgba(60,60,67,0.18)` | Disabled labels |
| `fill.primary` | `rgba(120,120,128,0.20)` | Pressed button bg, segmented track |
| `fill.secondary` | `rgba(120,120,128,0.16)` | Search bar background |
| `fill.tertiary` | `rgba(118,118,128,0.12)` | Quiet pill backgrounds |
| `fill.quaternary` | `rgba(116,116,128,0.08)` | Very quiet (hover-like) |
| `separator.opaque` | `#C6C6C8` | Solid divider where opacity must not double-up |
| `separator.nonOpaque` | `rgba(60,60,67,0.29)` | Standard 0.5pt hairline |
| `accent.primary` | `#0a7ea4` | Brand tint (kept from existing Colors.ts; calm teal, contrasts on white at 4.6:1) |
| `accent.success` | `#34C759` | iOS systemGreen |
| `accent.warning` | `#FF9F0A` | iOS systemOrange |
| `accent.error` | `#FF3B30` | iOS systemRed |
| `reader.paper` | `#FAF8F3` | Subtle off-white for book text bg in light mode (matches Apple Books default tone) |
| `reader.ink` | `#1C1C1E` | Book text color (slightly softened from pure black) |
| `reader.paperPureWhite` | `#FFFFFF` | "White" theme variant — kept for parity with existing `READER_THEMES.white` |
| `reader.paperSepia` | `#F6F0E2` | Sepia theme (matches existing `READER_THEMES.yellow.background`) |
| `highlight.yellow` | `rgba(255,224,102,0.45)` | Tint 1 — matches electron HighlightLayer yellow |
| `highlight.green` | `rgba(143,225,158,0.45)` | Tint 2 |
| `highlight.blue` | `rgba(143,196,255,0.45)` | Tint 3 |
| `highlight.pink` | `rgba(255,170,200,0.45)` | Tint 4 |
| `highlight.purple` | `rgba(204,178,242,0.45)` | Tint 5 |

### 1.2 Dark palette

| Token | Value | Description |
|---|---|---|
| `background.primary` | `#000000` | True black, OLED-friendly, Apple Books-style |
| `background.secondary` | `#1C1C1E` | Elevated surfaces (sheets, modals) |
| `background.tertiary` | `#2C2C2E` | Higher elevation (nested cells) |
| `background.grouped` | `#000000` | Grouped list canvas |
| `label.primary` | `#FFFFFF` | Primary text |
| `label.secondary` | `rgba(235,235,245,0.60)` | Secondary text |
| `label.tertiary` | `rgba(235,235,245,0.30)` | Placeholder |
| `label.quaternary` | `rgba(235,235,245,0.18)` | Disabled |
| `fill.primary` | `rgba(120,120,128,0.36)` | Pressed bg |
| `fill.secondary` | `rgba(120,120,128,0.32)` | Search bar |
| `fill.tertiary` | `rgba(118,118,128,0.24)` | Quiet pills |
| `fill.quaternary` | `rgba(118,118,128,0.18)` | Very quiet |
| `separator.opaque` | `#38383A` | Solid divider |
| `separator.nonOpaque` | `rgba(84,84,88,0.65)` | 0.5pt hairline |
| `accent.primary` | `#3AB4D6` | Lightened `#0a7ea4` (contrast on #000 = 5.4:1) |
| `accent.success` | `#30D158` | iOS systemGreen (dark) |
| `accent.warning` | `#FF9F0A` | iOS systemOrange (dark) |
| `accent.error` | `#FF453A` | iOS systemRed (dark) |
| `reader.paper` | `#000000` | Dark theme book bg — Apple Books true black |
| `reader.ink` | `#B8B8B9` | Slightly dim white (matches existing `READER_THEMES.dark.color`) |
| `reader.paperPureWhite` | `#FFFFFF` | Pure-white reader option (forced) |
| `reader.paperSepia` | `#F6F0E2` | Sepia (forced) |
| `highlight.yellow` | `rgba(255,224,102,0.32)` | Slightly reduced alpha on dark |
| `highlight.green` | `rgba(143,225,158,0.32)` |  |
| `highlight.blue` | `rgba(143,196,255,0.32)` |  |
| `highlight.pink` | `rgba(255,170,200,0.32)` |  |
| `highlight.purple` | `rgba(204,178,242,0.32)` |  |

Notes:
- Reader theme tokens preserve the four user-selectable reader backgrounds (paperPureWhite / paper / paperSepia / dark). `reader.paper` in light = subtle warm white. In dark = true black. Existing `READER_THEMES.{white,yellow,dark}` map cleanly onto these tokens; the migration is straightforward.
- Brand accent `#0a7ea4` is preserved in light. Dark uses `#3AB4D6` (a perceptually lifted version) so it stays visible on true black without becoming a neon glow.

---

## 2. Typography scale

Font families (resolved via `Platform.select`):

```ts
// Resolved at hook-read time, exported through useTheme().typography.family
family: {
  sans:  Platform.select({ ios: 'system-ui',  default: 'normal' }),   // SF Pro on iOS
  serif: Platform.select({ ios: 'ui-serif',   default: 'serif' }),    // New York on iOS
  rounded: Platform.select({ ios: 'ui-rounded', default: 'normal' }), // SF Pro Rounded
  mono:  Platform.select({ ios: 'ui-monospace', default: 'monospace' })
}
```

Rely on iOS system serif (`ui-serif`) which on iOS 13+ resolves to New York. On Android we fall back to platform serif (typically Noto Serif). No bundled font files needed for Phase 2.

### 2.1 Scale

| Token | Size (pt) | Weight | Line height (pt) | Use |
|---|---|---|---|---|
| `display-large` | 34 | semibold | 41 | Large screen titles ("Library") |
| `display` | 28 | semibold | 34 | Section hero |
| `title` | 22 | semibold | 28 | Sheet titles, section headers |
| `body` | 17 | regular | 22 | Primary text |
| `callout` | 16 | regular | 21 | Slightly emphasized body |
| `subhead` | 15 | regular | 20 | Subheads, captions in lists |
| `footnote` | 13 | regular | 18 | Footnote, secondary info |
| `caption` | 12 | regular | 16 | Small caption |
| `caption-small` | 11 | regular | 13 | Smallest readable text |
| `reader-body` | user 14–22 | regular | 1.5× line-height | NY serif, book content |

### 2.2 Weight tokens

| Token | Value |
|---|---|
| `regular` | `'400'` |
| `medium` | `'500'` |
| `semibold` | `'600'` |
| `bold` | `'700'` |

### 2.3 Line-height tokens

| Token | Multiplier |
|---|---|
| `tight` | 1.2 |
| `normal` | 1.4 |
| `relaxed` | 1.5 |

`reader-body` uses `relaxed`. Chrome uses `normal`. Display sizes use `tight`.

Dynamic Type: all tokens are pt-based and respect RN's default `allowFontScaling={true}`. Do not pass `false` anywhere — Dynamic Type must work.

---

## 3. Spacing scale (4pt grid)

| Token | Value (pt) |
|---|---|
| `none` | 0 |
| `xxs` | 2 |
| `xs` | 4 |
| `sm` | 8 |
| `md` | 12 |
| `lg` | 16 |
| `xl` | 20 |
| `2xl` | 24 |
| `3xl` | 32 |
| `4xl` | 40 |
| `5xl` | 56 |
| `6xl` | 80 |

Use:
- Chrome horizontal padding: `lg` (16)
- Reader content horizontal padding (iPhone): `2xl` (24)
- Sheet body padding: `lg` horizontal, `xl` top, safe-area bottom
- Stack gaps between list rows: 0 (rows are full-bleed with hairline separator)
- Stack gaps in onboarding / hero: `xl` (20)

---

## 4. Radius scale

| Token | Value (pt) |
|---|---|
| `none` | 0 |
| `sm` | 6 |
| `md` | 10 |
| `lg` | 14 |
| `xl` | 20 |
| `full` | 9999 |

Defaults:
- Book covers: `md` (10)
- Pills (progress, status): `full`
- Sheets: top corners `xl` (20) — matches `@gorhom/bottom-sheet` Apple-ish default
- Buttons / segmented control: `lg` (14)
- Search bar: `lg` (14)

---

## 5. Motion vocabulary

All motion lives in `motion` tokens. Reanimated 4 consumers read spring/timing configs directly; non-Reanimated consumers (e.g. RN `Animated`) read `duration` + `easing`.

| Token | Type | Config | Use |
|---|---|---|---|
| `spring.gentle` | spring | `{ damping: 18, stiffness: 250, mass: 1 }` → critically-damped feel (ratio ≈ 0.85) | Sheet open, modal enter, content reveal |
| `spring.snappy` | spring | `{ damping: 22, stiffness: 400, mass: 1 }` → ratio ≈ 0.80 | Button press scale, segmented control highlight |
| `spring.bouncy` | spring | `{ damping: 12, stiffness: 200, mass: 1 }` → ratio ≈ 0.60 | Mini-player wobble, playful surfaces |
| `timing.fast` | timing | `{ duration: 200, easing: Easing.out(Easing.quad) }` | Backdrop fades, hairline pops |
| `timing.normal` | timing | `{ duration: 300, easing: Easing.out(Easing.quad) }` | Content reveals, toolbar tap-toggle |
| `timing.slow` | timing | `{ duration: 500, easing: Easing.inOut(Easing.quad) }` | Book-cover hero transitions, page swap |

Note on damping ratio: Reanimated's `damping` is the absolute coefficient. With `stiffness=250, mass=1` the critical damping is `2·sqrt(stiffness·mass) ≈ 31.6`. So `damping=18` gives a ratio of `0.57` — but in practice this *feels* like the Apple-Books "soft settle." If we want the literal "0.85 damping ratio" feel, multiply: `damping = 0.85 × 2 × sqrt(stiffness)`. The architect should pick one of these readings and document it once in `motion.ts`. **Recommended:** treat the user-facing constants above as Reanimated-native (`damping=18, stiffness=250` etc.) since these have been hand-tuned against Apple Books in the past — do not algebra-convert.

### Reduce-motion fallback

`useTheme()` exposes `reduceMotion: boolean` (sourced from `AccessibilityInfo.isReduceMotionEnabled` + subscription). When `true`:
- Replace any spring with `timing.normal`
- Replace `timing.slow` with `timing.fast`
- Backdrop fades only; no slide-from-bottom — sheets fade in place
- PressableScale becomes opacity-only (0.7 on press) — no scale transform

---

## 6. Elevation / blur

### 6.1 Shadows

Apple Books uses very subtle shadows. Avoid Material-style elevation.

| Token | iOS shadow | Android elevation |
|---|---|---|
| `flat` | none | 0 |
| `low` | `shadowColor:'#000', shadowOffset:{w:0,h:1}, shadowOpacity:0.06, shadowRadius:2` | 1 |
| `medium` | `shadowColor:'#000', shadowOffset:{w:0,h:6}, shadowOpacity:0.12, shadowRadius:14` | 8 |
| `high` | `shadowColor:'#000', shadowOffset:{w:0,h:12}, shadowOpacity:0.18, shadowRadius:28` | 16 |

Use:
- `low` — book covers in grid
- `medium` — bottom sheets (rendered by `@gorhom/bottom-sheet` defaultBackground; we tweak via `containerStyle`)
- `high` — full-screen modals over a tinted backdrop

In dark mode, shadows are visually weaker (true black canvas). Multiply `shadowOpacity` by 0.5 in dark.

### 6.2 Glass blur

For Phase 4 floating widgets and Phase 3 transparent toolbars.

```ts
glass: {
  intensity: 80,                    // expo-blur Intensity (0-100); 80 ≈ UIBlurEffectStyleSystemMaterial
  tint: scheme === 'dark' ? 'systemUltraThinMaterialDark' : 'systemUltraThinMaterialLight',
  // RN equivalent if we ever drop expo-blur:
  fallback: scheme === 'dark' ? 'rgba(28,28,30,0.72)' : 'rgba(255,255,255,0.72)'
}
```

`expo-blur` `<BlurView>` accepts `intensity` (0-100) and `tint`. The "saturate 180%" requirement is handled natively by `systemMaterial` tint variants — we don't expose a saturate token.

---

## 7. Primitives

All primitives live under `apps/mobile/components/ui/`. Each primitive reads tokens via `useTheme()`. No primitive owns colors; all are theme-driven.

### a. `Sheet.tsx`

Path: `apps/mobile/components/ui/Sheet.tsx`

Wrapper around `@gorhom/bottom-sheet`'s `BottomSheetModal`. Encapsulates: grabber, backdrop with tap-close, safe-area bottom padding, optional title row, theme-driven background.

```ts
import type { ReactNode } from 'react';

export type SheetProps = {
  isOpen: boolean;
  onClose: () => void;
  snapPoints?: Array<string | number>;   // default: ['50%']
  enableDynamicSizing?: boolean;          // default: true if snapPoints undefined
  children: ReactNode;
  title?: string;
  accessibilityLabel?: string;            // defaults to title
  showGrabber?: boolean;                  // default: true
  // Allow caller to override scrolling behavior of the body
  scrollable?: boolean;                   // default: false → uses BottomSheetView
};
```

Behavior:
- Mounts a `BottomSheetModal` via the global `BottomSheetModalProvider` (assumed at root in `_layout.tsx`).
- `onChange` index `-1` triggers `onClose()`.
- `backdropComponent` = custom `BottomSheetBackdrop` with `pressBehavior="close"`, `appearsOnIndex={0}`, `disappearsOnIndex={-1}`.
- `handleIndicatorStyle` styled with `fill.tertiary` (the grabber pill is 36×5pt, radius `full`).
- `backgroundStyle` uses `colors.background.secondary` (light) / `colors.background.secondary` (dark = `#1C1C1E`).
- Bottom padding = `useSafeAreaInsets().bottom + spacing.lg`.
- Optional title row: 22pt semibold, centered, with `spacing.lg` vertical padding, hairline below.
- Reduce-motion: pass `animationConfigs` with `timing.normal` instead of spring.

Accessibility:
- Container `accessibilityViewIsModal={true}`
- `accessibilityLabel` falls back to `title`
- VoiceOver: announces title on open

States: open / closed. No "pressed" — Sheet is a surface.

### b. `Toolbar.tsx`

Path: `apps/mobile/components/ui/Toolbar.tsx`

```ts
export type ToolbarProps = {
  position: 'top' | 'bottom';
  left?: ReactNode;
  center?: ReactNode;
  right?: ReactNode;
  transparent?: boolean;       // default: false → opaque background.primary
  blur?: boolean;              // default: false → if true, wraps in <BlurView>
  hairline?: boolean;          // default: true on top (bottom edge), bottom (top edge)
  testID?: string;
};
```

Behavior:
- `safe-area-context` for the leading edge: top adds `insets.top` to padding-top, bottom adds `insets.bottom` to padding-bottom.
- Three slots in a row: `left` aligned start, `center` aligned center (absolute positioning so left/right widths don't push it), `right` aligned end.
- Min height: 44 (iOS nav bar), tap targets honor 44×44 inside.
- `blur=true` renders `<BlurView intensity={80} tint=...>` as background with absolute fill; `transparent` should also be true for blur to be visible.
- `hairline=true` adds a `<Hairline>` at the opposite edge from the safe area (top toolbar → bottom hairline, bottom toolbar → top hairline).

States: default only — Toolbar is a layout container.

Accessibility:
- `accessibilityRole="toolbar"` on the container.

### c. `IconButton.tsx`

Path: `apps/mobile/components/ui/IconButton.tsx`

```ts
import type { Ionicons } from '@expo/vector-icons';

export type IconButtonProps = {
  name: keyof typeof Ionicons.glyphMap;
  onPress: () => void;
  size?: number;                             // default: 22
  color?: string;                            // default: colors.label.primary
  label: string;                             // REQUIRED VoiceOver label
  hitSlop?: number | { top: number; bottom: number; left: number; right: number };
  haptic?: 'selection' | 'soft' | 'medium';  // default: 'selection'
  disabled?: boolean;
  testID?: string;
};
```

Behavior:
- Wraps `<PressableScale>` with scale-to-0.95.
- On press: `Haptics.selectionAsync()` for `selection`, `Haptics.impactAsync(Soft)` for `soft`, `Haptics.impactAsync(Medium)` for `medium`. No haptic when `disabled`.
- Renders `<Ionicons name={name} size={size} color={effectiveColor} />`.
- `hitSlop` default = 8 on all sides (so a 22pt icon hits ~38×38; if visible target <44, caller sets larger hitSlop).
- Disabled: color is `label.quaternary`; press handler is a no-op (do not pass `disabled` to Pressable so VoiceOver still announces, then provide `accessibilityState={{ disabled: true }}`).

Accessibility:
- `accessibilityRole="button"`
- `accessibilityLabel={label}` — required prop (type-enforced).
- `accessibilityState={{ disabled }}`

States: default, pressed (scale 0.95), disabled (lower opacity / quaternary color).

### d. `Hairline.tsx`

Path: `apps/mobile/components/ui/Hairline.tsx`

```ts
export type HairlineProps = {
  orientation?: 'horizontal' | 'vertical';   // default: 'horizontal'
  color?: string;                            // default: colors.separator.nonOpaque
  inset?: number;                            // default: 0 — horizontal: left inset; vertical: top inset
};
```

Behavior:
- Pure `<View>` with `StyleSheet.hairlineWidth` on the appropriate dimension.
- Horizontal: `{ height: StyleSheet.hairlineWidth, width: '100%' }` minus `inset` on left.
- Vertical: `{ width: StyleSheet.hairlineWidth, height: '100%' }`.

Accessibility: `accessible={false}` (decorative).

### e. `PressableScale.tsx`

Path: `apps/mobile/components/ui/PressableScale.tsx`

```ts
export type PressableScaleProps = {
  children: ReactNode;
  onPress: () => void;
  onPressIn?: () => void;
  onPressOut?: () => void;
  hitSlop?: number | { top: number; bottom: number; left: number; right: number };
  scale?: number;                            // default: 0.95
  disabled?: boolean;
  accessibilityLabel: string;                // REQUIRED
  accessibilityRole?: 'button' | 'link' | 'imagebutton' | 'menuitem';  // default: 'button'
  accessibilityHint?: string;
  style?: ViewStyle;
  testID?: string;
};
```

Behavior:
- Reanimated 4 `useSharedValue(1)` for scale.
- On `onPressIn`: `scale.value = withSpring(props.scale ?? 0.95, motion.spring.snappy)`.
- On `onPressOut`: `scale.value = withSpring(1, motion.spring.snappy)`.
- `Animated.View` wraps children with `transform:[{ scale }]`.
- Reduce-motion fallback: replace transform with opacity (0.7 on press, 1 on release) via `withTiming(value, motion.timing.fast)`.
- `hitSlop` default = 0 (caller sets per use).

Accessibility:
- `accessibilityRole`, `accessibilityLabel`, `accessibilityHint`, `accessibilityState={{ disabled }}`.

States: default, pressed (scale), disabled (opacity 0.4, no animation).

### f. `BookCover.tsx`

Path: `apps/mobile/components/ui/BookCover.tsx`

```ts
export type BookCoverProps = {
  uri?: string | null;
  title: string;
  size: 'sm' | 'md' | 'lg';
  aspectRatio?: number;                       // default: 2/3 (book proportion)
  rounded?: keyof Radius;                     // default: 'md'
  elevation?: 'flat' | 'low' | 'medium';      // default: 'low'
  testID?: string;
};
```

Behavior:
- Size map: `sm` = 48pt width, `md` = 96pt, `lg` = 144pt. Height derived from `aspectRatio`.
- If `uri` provided: `<Image source={{ uri }} style={{ borderRadius }} contentFit="cover" />` via `expo-image`.
- Fallback (no uri or error): solid background using a deterministic hash of `title` → one of 8 pleasing gradients (single-color OK for v1); centered display-large of `title[0].toUpperCase()` in `label.primary`-contrasting color.
- Rounded corners via `borderRadius` from `radius` tokens.
- Elevation via shadow tokens.
- `contentFit="cover"`. Border `0.5pt separator.nonOpaque` to give covers a subtle edge on white backgrounds (mirrors Apple Books).

Accessibility:
- `accessibilityRole="image"`
- `accessibilityLabel={`Cover of ${title}`}`

States: default, error-fallback. No interactive states (cover is wrapped by `PressableScale` at the caller when needed).

### g. `SegmentedControl.tsx`

Path: `apps/mobile/components/ui/SegmentedControl.tsx`

```ts
export type SegmentedControlOption<T extends string> = { label: string; value: T };
export type SegmentedControlProps<T extends string> = {
  value: T;
  onChange: (next: T) => void;
  options: ReadonlyArray<SegmentedControlOption<T>>;
  fullWidth?: boolean;                       // default: false
  size?: 'sm' | 'md';                        // default: 'md'
  testID?: string;
};
```

Behavior:
- Track background: `fill.primary`. Radius: `lg`.
- Highlight pill: solid `background.primary` (light) / `fill.tertiary` (dark) with `shadow.low`.
- Pressing a segment animates the pill's `translateX` with `motion.spring.snappy`.
- Selection haptic: `Haptics.selectionAsync()` on change.
- `fullWidth=true` stretches to container; otherwise sized to content + `spacing.md` per segment.
- `size='sm'` = 28pt height, font `footnote`. `size='md'` = 36pt height, font `subhead` semibold.

Accessibility:
- Container `accessibilityRole="tablist"`.
- Each segment `accessibilityRole="tab"`, `accessibilityState={{ selected }}`, `accessibilityLabel={option.label}`.

States: default, selected (pill behind), pressed (segment opacity 0.7).

### h. `SearchBar.tsx`

Path: `apps/mobile/components/ui/SearchBar.tsx`

```ts
export type SearchBarProps = {
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;                      // default: 'Search'
  onClear?: () => void;                      // if undefined, internal handler clears value
  onCancel?: () => void;                     // if provided, Cancel button shown on focus
  onSubmit?: () => void;
  autoFocus?: boolean;
  testID?: string;
};
```

Behavior:
- Container row: search icon (Ionicons `search`) + `<TextInput>` + clear button (`close-circle`).
- Background: `fill.secondary`, radius `lg`, height 36pt, horizontal padding `md`.
- Placeholder color: `label.tertiary`.
- On focus: animate Cancel button into view from the right (`motion.timing.normal`); container shrinks to make room. On blur or Cancel-press, animation reverses.
- Clear button visible only when `value.length > 0`.

Accessibility:
- `<TextInput>` `accessibilityLabel="Search"`, `returnKeyType="search"`.
- Cancel button is a `PressableScale` with `accessibilityLabel="Cancel"`.
- Clear button is `IconButton` with `label="Clear search"`.

States: empty, typing, focused-with-cancel, blurred.

### i. `ListRow.tsx`

Path: `apps/mobile/components/ui/ListRow.tsx`

```ts
export type ListRowAccessory =
  | 'chevron'
  | 'check'
  | { kind: 'switch'; value: boolean; onValueChange: (next: boolean) => void }
  | { kind: 'custom'; node: ReactNode };

export type ListRowProps = {
  icon?: ReactNode;                          // typically <Ionicons /> 22pt
  title: string;
  subtitle?: string;
  accessory?: ListRowAccessory;
  value?: string;                            // right-aligned text (e.g. "Off", "1.2 MB")
  onPress?: () => void;                      // omit to render non-interactive row
  destructive?: boolean;                     // default: false → title in accent.error
  testID?: string;
};
```

Behavior:
- Min height 44pt; vertical padding `sm`, horizontal padding `lg`.
- Icon leading, then title/subtitle stacked, then value (`label.secondary`), then accessory.
- `chevron` → small Ionicons `chevron-forward` in `label.tertiary`.
- `check` → Ionicons `checkmark` in `accent.primary`.
- `switch` → RN `<Switch>` themed (`trackColor.true = accent.primary`).
- If `onPress` provided, wrap in `PressableScale` with `scale=0.99` (subtle) + `fill.quaternary` flash on press; haptic `selection`.
- Bottom hairline rendered by the parent list (rows do not own dividers; use `<Hairline inset={icon ? 56 : 16} />`).

Accessibility:
- Pressable rows: `accessibilityRole="button"`, `accessibilityLabel={title}`, `accessibilityHint={subtitle}`.
- Switch rows: container `accessible={false}`; the switch itself owns accessibility.
- Destructive: include "destructive" in label (e.g. "Delete book, destructive").

States: default, pressed, disabled (caller passes `onPress={undefined}` and sets opacity manually if needed — keep this primitive lean).

### j. `EmptyState.tsx`

Path: `apps/mobile/components/ui/EmptyState.tsx`

```ts
export type EmptyStateProps = {
  icon: keyof typeof Ionicons.glyphMap | ReactNode;
  title: string;
  description?: string;
  action?: { label: string; onPress: () => void };
  testID?: string;
};
```

Behavior:
- Centered vertical stack with `spacing.xl` between elements.
- Icon: 56pt in `label.tertiary` (decorative; or caller-supplied node).
- Title: `title` token, color `label.primary`, centered.
- Description: `body` token, color `label.secondary`, centered, max width 320pt.
- Action: rendered as a filled pill button (height 44, radius `full`, bg `accent.primary`, label `body` semibold white). Wraps `PressableScale` with `medium` haptic on press.
- Padding: `2xl` horizontal, `5xl` top.

Accessibility:
- Container `accessibilityRole="summary"`.
- Action button `accessibilityRole="button"`, `accessibilityLabel={action.label}`.

States: default; action button: default / pressed / disabled.

---

## 8. Theme hook

Path: `apps/mobile/lib/theme/useTheme.ts`

```ts
import { useColorScheme, AccessibilityInfo } from 'react-native';
import { useEffect, useState, useMemo } from 'react';
import { colorsLight, colorsDark } from './colors';
import { typography } from './typography';
import { spacing, radius, motion, shadow } from './tokens';

export type Theme = {
  scheme: 'light' | 'dark';
  colors: typeof colorsLight;
  typography: typeof typography;
  spacing: typeof spacing;
  radius: typeof radius;
  motion: typeof motion;
  shadow: typeof shadow;
  reduceMotion: boolean;
};

export function useTheme(): Theme {
  const systemScheme = useColorScheme() ?? 'light';
  const [reduceMotion, setReduceMotion] = useState(false);

  useEffect(() => {
    let cancelled = false;
    AccessibilityInfo.isReduceMotionEnabled().then((v) => {
      if (!cancelled) setReduceMotion(v);
    });
    const sub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => { cancelled = true; sub.remove(); };
  }, []);

  return useMemo(() => ({
    scheme: systemScheme,
    colors: systemScheme === 'dark' ? colorsDark : colorsLight,
    typography,
    spacing,
    radius,
    motion,
    shadow,
    reduceMotion,
  }), [systemScheme, reduceMotion]);
}
```

Notes:
- Returns a stable object via `useMemo` so consumers can safely include `theme` in dependency arrays.
- User override (manual light/dark selection) is **out of scope for Phase 2**. When Phase 6 adds it, persist to MMKV under key `theme:scheme-override` and OR-in to `systemScheme` resolution. Hook signature does not need to change.

Subscriptions:
- `useColorScheme()` already subscribes to system changes.
- `reduceMotion` subscribes via `AccessibilityInfo`.

`useTheme()` replaces `useThemeColor()` for new code. Keep `useThemeColor()` working through Phase 3 (existing call sites) by re-implementing it as a thin shim over `useTheme()` — left for the architect / Phase 3 migration.

---

## 9. Token file layout

**Pick: mobile-local for Phase 2.** Justification:
1. Colors include rgba opacities tuned for RN compositing (e.g. fill rgba over various bgs). Sharing to web/electron would require either pre-multiplying or re-deriving — not worth the complexity yet.
2. Typography resolves to `Platform.select` font family strings — inherently mobile-only.
3. Motion configs use Reanimated spring shape (`damping`, `stiffness`, `mass`) — different from Framer Motion / electron's CSS keyframes.
4. The "shared theme" extraction is a Phase 6 polish if it pays off; doing it now is premature abstraction.

Layout:

```
apps/mobile/lib/theme/
  tokens.ts         # spacing, radius, motion, shadow (pure numerics)
  colors.ts         # colorsLight, colorsDark (flat keyed records)
  typography.ts     # family (Platform.select), scale, weights, lineHeights
  useTheme.ts       # the hook (Section 8)
  index.ts          # barrel: export { useTheme } and re-export all token shapes/types
```

Naming: lowercase filenames to match existing `apps/mobile/lib/` convention (e.g. `book-storage.ts`, `reader-settings.ts`).

What goes where:
- `tokens.ts` — `spacing`, `radius`, `motion`, `shadow`. No colors, no fonts. Pure numbers + easing/spring objects. Exported as `const … as const` for narrow types.
- `colors.ts` — exports `colorsLight: ColorTokens`, `colorsDark: ColorTokens`, and type `ColorTokens` derived from `typeof colorsLight`.
- `typography.ts` — exports `typography: { family, scale, weights, lineHeights }`. `family` is the `Platform.select` block. `scale` is a record of all type tokens with `{ fontSize, fontWeight, lineHeight, family: 'sans'|'serif' }`.
- `useTheme.ts` — the hook + `Theme` type alias.
- `index.ts` — barrel re-exports for tidy imports: `import { useTheme, type Theme } from '@/lib/theme'`.

`packages/shared` is not touched in Phase 2. Future extraction lives behind a separate design discussion.

---

## 10. Accessibility baseline

Non-negotiable requirements that primitives MUST honor:

1. **Dynamic Type:** No primitive may pass `allowFontScaling={false}` to a `Text`. Default RN behavior is to scale; we keep it.
2. **VoiceOver labels:** `IconButton.label`, `PressableScale.accessibilityLabel`, `BookCover.title`-derived label, `Sheet.accessibilityLabel|title`, `ListRow.title`, `EmptyState.title|action.label` are **type-required props** (not optional). TS compile-time enforcement.
3. **Touch targets:** Minimum 44×44pt. Where the visual is smaller (icons in tight toolbars), the primitive's default `hitSlop` MUST inflate to 44×44. Document this for `IconButton`.
4. **Color contrast:**
   - Body text (`body` token and smaller) over `background.primary`: ≥ 4.5:1. Verified: light `#000` on `#FFF` = 21:1; dark `#FFF` on `#000` = 21:1; secondary labels rely on opaque equivalents (~`#3C3C43` light, `#EBEBF5` dark) — ≥ 4.5:1.
   - Large text (`title` and larger, ≥ 22pt): ≥ 3:1.
   - Accent over white: `#0a7ea4` on `#FFF` = 4.6:1 (passes for normal text).
   - Accent over black: `#3AB4D6` on `#000` = 5.4:1 (passes).
5. **Reduce Motion:** Spring → `timing.normal`; PressableScale → opacity fade; sheet slide → fade-in-place. Implemented in `useTheme().reduceMotion` and consumed by each primitive.
6. **Focus order / VoiceOver rotor:** Toolbars use `accessibilityRole="toolbar"`. Sheets use `accessibilityViewIsModal={true}` so VoiceOver does not escape to underlying content.
7. **Haptic policy:** Selection (light) for taps, Soft for sheet open / toggle, Success/Warning for state changes (Phase 3 wiring). Haptics MUST be skippable: respect `reduceMotion` as a proxy ("Reduce Motion ⇒ no haptics" is a reasonable correlate; iOS doesn't expose a "reduce haptics" flag).

---

## 11. Migration plan

| File | Phase | Notes |
|---|---|---|
| `components/ReaderToolbar.tsx` | **Phase 3** | Full redesign as part of reader UI. Phase 2 does not touch. |
| `components/AppearanceSheet.tsx` | **Phase 3** | Refactor to use `Sheet` + `SegmentedControl` + `ListRow`. |
| `components/TocSheet.tsx` | **Phase 3** | Refactor to `Sheet` + `ListRow` per TOC entry. |
| `components/HighlightsSheet.tsx` | **Phase 3** | Refactor to `Sheet` + `ListRow` + highlight tint chips. |
| `components/BookRow.tsx` | **Phase 2 (light)** | Replace inline cover image with `<BookCover>`; outer structure becomes `<ListRow>` if API fits, else stays bespoke. Keep behavior identical. |
| `app/(tabs)/index.tsx` (library) | **Phase 2 (light)** | Swap the grid item to render `<BookCover size="md">` for thumbnails. No layout overhaul (2-col portrait stays as is — actual grid redesign is Phase 3). |
| `components/themed-text.tsx` | **Phase 2 (additive)** | Keep file working; add `typography` token usage so new code can `import { Text } from '@/components/ui/Text'` (a thin wrapper if architect wants it) — otherwise it can simply read `useTheme().typography.scale.body` inline. **Recommended:** do not introduce a new `<Text>` primitive in Phase 2; let `ThemedText` survive until Phase 3. |
| `hooks/use-theme-color.ts` | **Phase 2 (compat shim)** | Re-implement as `useTheme().colors[…]` lookup so old callers keep working. Mark as deprecated in JSDoc. |
| `constants/theme.ts` (`Colors`, `Fonts`) | **Phase 2 (keep)** | Do not delete. `useTheme()` derives from `lib/theme/colors.ts`; old `Colors` constant lives until Phase 3 migration completes, then removed. |
| `constants/reader-themes.ts` | **Phase 3** | Reader theme migration handled when reader is redesigned. |
| All other existing components | **Phase 3+** | Touched only when their host screen migrates. |

**Statement:** Phase 2 builds the foundation. Phase 3 applies it. No screen-level visual change is required to "complete" Phase 2 — completing primitives + tokens + hook with green tests is sufficient. The two "Phase 2 (light)" entries (`BookRow.tsx` + library tab) are smoke tests proving the primitives work in real code.

---

## 12. Visual reference notes (Apple Books observations)

Concrete observations to inform the architect's implementation choices (do not pixel-clone):

1. **Library grid**
   - Portrait iPhone: 2-column grid, ~165pt-wide covers with `spacing.lg` gutter, `2xl` horizontal page padding.
   - Landscape / iPad: 4-column.
   - Each cover sits over a "Want to Read" / progress hint as a small subhead caption directly below (no card chrome — just title + caption).
   - Recent-read items have a tiny progress sliver under the cover (use a `Hairline`-thin bar at `accent.primary`, not a full progress bar — Phase 3 detail).

2. **Reader chrome**
   - 24pt (`2xl`) horizontal padding around text on iPhone; safe-area-aware top.
   - Chapter title floats at top with **no background fill** (label only) when chrome is hidden. Phase 3.
   - Bottom: a pill (radius `full`, `fill.tertiary` background) showing `page X of Y` or `XX% • XX min left`. Sits in a `Toolbar` slot.
   - **One tap** anywhere on text toggles top + bottom chrome. **Two taps** zooms PDFs (Phase 3).

3. **Bottom sheets for everything secondary**
   - TOC, bookmarks, highlights, appearance, search — all sheets.
   - Sheets reach to ~75% height by default; appearance sheet is shorter (~45%).
   - Sheet body uses `background.secondary` (`#F2F2F7` light / `#1C1C1E` dark) — clearly differentiated from the reader's `reader.paper`.

4. **Appearance sheet contents (Phase 3 reference)**
   - Font-size slider (range matches `reader-body` 14–22pt token range).
   - Font picker: multi-line preview row per font (sans + serif options).
   - Theme color tiles: 4 swatches (white / sepia / gray / black) — `BookCover`-sized circles via `radius.full`.
   - Brightness slider at top.

5. **Motion**
   - Sheet open: gentle spring from bottom (existing `@gorhom/bottom-sheet` default is close — pass `animationConfigs` for `motion.spring.gentle` to match).
   - Page turn (Phase 3): fade-cross at `timing.normal`. **No** curl, **no** slide-from-side.
   - Tap toolbar: fade-in chrome at `timing.fast`. Hairline animates in last.

6. **Haptic register**
   - Open sheet: `Soft` impact when sheet hits open position (not on the tap — on the *settle*).
   - Toggle highlight color: `Selection`.
   - Bookmark add / remove: `Success` notification.
   - Sign-out / destructive: `Warning` then native confirm dialog.

7. **What we explicitly DO NOT replicate**
   - Page-curl animation (deferred in master design — non-goal).
   - "Reading Goals" / streak surface (no parity scope).
   - Audiobook playback chrome — we have our own `MiniPlayer` (Phase 4).
   - Apple-Books-exact font (Bookerly / Charter) — we use iOS system serif (`ui-serif` → New York on iOS 13+).

---

## Token JSON sketch (for the architect)

Skeleton the architect can lift into `tokens.ts`. Numeric values only; no behavior.

```ts
// apps/mobile/lib/theme/tokens.ts
export const spacing = {
  none: 0, xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 20,
  '2xl': 24, '3xl': 32, '4xl': 40, '5xl': 56, '6xl': 80,
} as const;

export const radius = {
  none: 0, sm: 6, md: 10, lg: 14, xl: 20, full: 9999,
} as const;

export const motion = {
  spring: {
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
  flat:   { shadowColor: '#000', shadowOpacity: 0, shadowRadius: 0, shadowOffset: { width: 0, height: 0 }, elevation: 0 },
  low:    { shadowColor: '#000', shadowOpacity: 0.06, shadowRadius: 2,  shadowOffset: { width: 0, height: 1  }, elevation: 1  },
  medium: { shadowColor: '#000', shadowOpacity: 0.12, shadowRadius: 14, shadowOffset: { width: 0, height: 6  }, elevation: 8  },
  high:   { shadowColor: '#000', shadowOpacity: 0.18, shadowRadius: 28, shadowOffset: { width: 0, height: 12 }, elevation: 16 },
} as const;
```

```ts
// apps/mobile/lib/theme/typography.ts (skeleton)
import { Platform } from 'react-native';

export const typography = {
  family: Platform.select({
    ios:     { sans: 'system-ui', serif: 'ui-serif', rounded: 'ui-rounded', mono: 'ui-monospace' },
    default: { sans: 'normal',     serif: 'serif',    rounded: 'normal',     mono: 'monospace' },
  })!,
  weights: { regular: '400', medium: '500', semibold: '600', bold: '700' } as const,
  lineHeights: { tight: 1.2, normal: 1.4, relaxed: 1.5 } as const,
  scale: {
    'display-large': { fontSize: 34, fontWeight: '600', lineHeight: 41, family: 'sans' },
    'display':       { fontSize: 28, fontWeight: '600', lineHeight: 34, family: 'sans' },
    'title':         { fontSize: 22, fontWeight: '600', lineHeight: 28, family: 'sans' },
    'body':          { fontSize: 17, fontWeight: '400', lineHeight: 22, family: 'sans' },
    'callout':       { fontSize: 16, fontWeight: '400', lineHeight: 21, family: 'sans' },
    'subhead':       { fontSize: 15, fontWeight: '400', lineHeight: 20, family: 'sans' },
    'footnote':      { fontSize: 13, fontWeight: '400', lineHeight: 18, family: 'sans' },
    'caption':       { fontSize: 12, fontWeight: '400', lineHeight: 16, family: 'sans' },
    'caption-small': { fontSize: 11, fontWeight: '400', lineHeight: 13, family: 'sans' },
    // reader-body fontSize is user-controlled at runtime; family is serif; lineHeight uses relaxed multiplier
    'reader-body':   { fontSize: 17, fontWeight: '400', lineHeight: 25.5, family: 'serif' },
  },
} as const;
```

---

## Open questions for the architect

1. **Damping ratio convention** — adopt the Reanimated-native interpretation (raw `damping`/`stiffness` numbers as written here) or convert to literal ratios? My recommendation: keep raw values, document once. (See Section 5.)
2. **`expo-blur` install** — please add to mobile package deps as part of Phase 2 scaffolding. Tiny dep, single platform addition.
3. **`ThemedText` future** — keep as-is for Phase 2, deprecate in Phase 3 in favor of `useTheme().typography.scale.*` inline. Confirmed.
4. **`useThemeColor` shim vs hard cut** — recommend shim for Phase 2 to avoid touching every existing call site. Confirmed.
5. **Nativewind interaction** — primitives use `StyleSheet` + tokens, not Nativewind classes. Existing screens that use Nativewind keep working; no migration to Nativewind for the new primitives. Confirmed.

---

End of UI-SPEC. Architect: please produce the file plan in `.parity-v2/phase2-design-system/PLAN.md`.
