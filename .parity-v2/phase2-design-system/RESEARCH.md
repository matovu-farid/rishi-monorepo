# Phase 2 Design System — Research

Date: 2026-05-22
Author: researcher agent
Next: designer (UI-SPEC.md done) → architect → tester → coder → reviewer

---

## 1. Mobile Current State

### 1.1 Token files

**No `lib/theme/` directory exists.** Tokens are fragmented across:

`apps/mobile/constants/theme.ts`:
- `Colors` object with light/dark variants, 6 roles each (`text`, `background`, `tint`, `icon`, `tabIconDefault`, `tabIconSelected`).
- `tintColorLight = '#0a7ea4'`, `tintColorDark = '#fff'`.
- `Fonts` via `Platform.select` mapping 4 axes (`sans`, `serif`, `rounded`, `mono`) to system font family strings. iOS uses `'system-ui'` / `'ui-serif'` / `'ui-rounded'` / `'ui-monospace'`.

`apps/mobile/constants/reader-themes.ts`:
- 3 `ReaderTheme` objects (white / dark / yellow/sepia) with 7 fields each — passed into epub.js `changeTheme`.

No spacing scale, no motion/animation presets, no elevation/shadow tokens, no type scale.

### 1.2 Theming mechanism

- `app/_layout.tsx` uses `@react-navigation/native` `ThemeProvider` with `DarkTheme`/`DefaultTheme`.
- NativeWind v4 installed; `tailwind.config.js` has **zero custom tokens**.
- `app.json` declares `"userInterfaceStyle": "automatic"`.

### 1.3 Existing primitives in `components/ui/`

Only `icon-symbol.tsx` (SF Symbols on iOS via `expo-symbols`, MaterialIcons fallback). All 6 required Phase 2 primitives must be built.

### 1.4 Bottom sheet usage

`@gorhom/bottom-sheet@5.2.8` used in 7 places:

| Component | snapPoints | Backdrop |
|---|---|---|
| `AppearanceSheet` | `[280]` | no |
| `TocSheet` | `['50%','90%']` | no |
| `HighlightsSheet` | `['50%','90%']` | no |
| `BookmarksList` | `['50%','90%']` | no |
| `SearchPanel` | `['50%','90%']` | no |
| `NoteEditor` | (varies) | no |
| `PremiumFeatureSheet` | `enableDynamicSizing` | yes — uses `BottomSheetBackdrop` |

Reader sheets duplicate `backgroundStyle`/`handleIndicatorStyle` inline; grabber color is wrong (uses book text color instead of iOS separator). PremiumFeatureSheet is the canonical example.

### 1.5 Animation library

- `react-native-reanimated@4.1.1` installed
- Most components use layout animations (`FadeIn`, `SlideInDown`)
- Worklets (`useSharedValue`, `useAnimatedStyle`) in `RealtimeVoiceButton`, `VoiceMicButton`, `PremiumFeatureSheet`
- `expo-haptics@15.0.8` — used in `HapticTab` (Light on tab press) and `PremiumFeatureSheet`
- **`expo-blur` NOT installed** — toolbar blur requires native rebuild
- **`react-native-skia` NOT installed** — needed for Phase 4 launcher waveform

### 1.6 Hardcoded color hotspots

Brand tint `#0a7ea4` appears as raw hex literal in 11+ files: `AppearanceSheet`, `ChatInput`, `ChatMessage`, `LibraryEmptyState`, `TTSControls`, `ReaderToolbar`, `PremiumFeatureSheet`, `RealtimeVoiceButton`, `TocSheet`, `VoiceMicButton`, plus others.

Other repeated hex: `#687076` (muted text, 4+ files), `#9BA1A6` (tertiary, 4+ files), `#9CA3AF` (placeholder, 3+ files), `#DC2626` / `#ef4444` (destructive variants), `#FF3B30` (iOS red), `#60A5FA` (blue link), `rgba(28,28,30,0.97)` (iOS system gray 6).

Inline sizing — partial 4pt grid (16, 8, 12) but off-grid values exist (50, 56, 88). No tokenization.

### 1.7 Font setup

- No `expo-font` / `useFonts` anywhere. iOS resolves to SF Pro automatically.
- `Fonts` export in `constants/theme.ts` is **defined but unused**.
- Reader's `fontFamily` (`'serif' | 'sans-serif'`) injected into WebView CSS for book content only.

---

## 2. Electron Current State

### 2.1 Tailwind v4 + CSS variables

`apps/rishi-electron/src/renderer/src/styles/globals.css`:
- Tailwind v4 (CSS-first config via `@import "tailwindcss"`)
- shadcn/ui defaults using oklch color space
- Light `:root`: `--background: oklch(1 0 0)`, `--primary: oklch(0.21 0.006 285.885)` (dark gray, not brand)
- Dark `.dark`: `--background: oklch(0.141 0.005 285.823)`, `--border: oklch(1 0 0 / 10%)`
- `--radius: 0.625rem` (10px)
- Brand `#0a7ea4` does NOT appear in CSS vars; only inline in components

### 2.2 Glass-morphism pattern (copy-pasted in 3 files)

Identical `glassContainer` style in `TTSControls`, `AIChatOrb`, `VoiceChatLauncher`:
```
background: linear-gradient(135deg, rgba(255,255,255,0.30), rgba(255,255,255,0.12), rgba(200,210,230,0.16))
backdropFilter: blur(40px) saturate(180%)
border: 1px solid rgba(255,255,255,0.45)
boxShadow: 0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12), inset shadows
```

### 2.3 Reader chrome patterns

- `ReaderOverlayControls`: thin orchestrator (renders AIChatOrb when chatting, VoiceChatLauncher always, TTSControls when not)
- `ReaderTOC`: shadcn `Sheet side="left"`, `w-[300px]`/`sm:w-[400px]`
- `TTSControls` electron: most complex — `framer-motion AnimatePresence`, CSS transitions on width/height/radius, expand 250ms `cubic-bezier(0.34,1.56,0.64,1)`, collapse 200ms ease-in-out
- `AIChatOrb`: 52×52, CSS keyframes scaleY, 4 bars, stagger 0.15s; colors blue/amber/green/purple
- `VoiceChatLauncher`: 52×52, fixed `bottom:96 right:32`, Tailwind transitions

### 2.4 Typography

- No custom fonts loaded. System stack via Tailwind's `font-sans`.
- No serif applied to chrome. Reader content has its own CSS in WebView.

---

## 3. Reference: Apple Books Design Language

iOS HIG type scale (Regular weight unless noted):

| Style | Size | Weight |
|---|---|---|
| Large Title | 34pt | Regular |
| Title 1 | 28pt | Regular |
| Title 2 | 22pt | Regular |
| Title 3 | 20pt | Regular |
| Headline | 17pt | Semibold |
| Body | 17pt | Regular |
| Callout | 16pt | Regular |
| Subheadline | 15pt | Regular |
| Footnote | 13pt | Regular |
| Caption 1 | 12pt | Regular |
| Caption 2 | 11pt | Regular |

Hairlines:
- Light: `#C6C6C8` at full opacity, height `StyleSheet.hairlineWidth` (0.5pt on 3x screens)
- Dark: `rgba(84,84,88,0.65)` or `#38383A`
- Apple Books uses hairlines in light, none in dark

Spacing — 4pt grid:
- Touch target: 44×44pt
- Content horizontal: 16pt iPhone SE, 20pt standard, 20–24pt Plus/Max
- Sheet internal: 16pt H, 12–16pt V from grabber to first content
- Grabber: 36pt wide × 4pt tall, radius 2, centered, 8pt from top

iOS UIKit semantic colors:
- `label`: light `#000000`, dark `#FFFFFF`
- `secondaryLabel`: light `#6B6B6B`, dark `#8D8D93`
- `systemBackground`: light `#FFFFFF`, dark `#000000`
- `secondarySystemBackground`: light `#F2F2F7`, dark `#1C1C1E`
- `separator`: light `#C6C6C8`, dark `rgba(84,84,88,0.65)`
- `systemBlue` (tint): `#007AFF` light, `#0A84FF` dark

Blur surfaces — `expo-blur` `BlurView` `intensity={80}` `tint="systemMaterial"` approximates `.systemChromeMaterial`.

Motion (Apple named springs → Reanimated equivalents):
- Snappy: `damping: 20, stiffness: 400`
- Gentle: `damping: 15, stiffness: 150`
- Bouncy: `damping: 10, stiffness: 300`

Haptics:
- Tap toolbar icon: `ImpactFeedbackStyle.Light`
- Toggle: `ImpactFeedbackStyle.Soft`
- Bookmark: `NotificationFeedbackType.Success`
- Destructive confirm: `NotificationFeedbackType.Warning`

Minimal chrome:
- Toolbars on tap; auto-hide after ~3s (mobile already does this)
- Apple Books split: top toolbar (back + title), bottom toolbar (chapter + progress pill + action cluster)
- Current mobile `ReaderToolbar` is single-bar — must split in Phase 3

---

## 4. Extract to `packages/shared`

Only platform-agnostic values:

1. **Motion timings** (unitless numbers) — durations + spring `{damping, stiffness, mass}` tuples
2. **Type scale** (pt sizes) — iOS HIG canonical
3. **Spacing scale** — 4pt grid tuple
4. **Color role names** (string enum, NO hex) — semantic vocabulary only
5. **AIChatOrb status→color map** — shared between electron and future mobile orb

**Do NOT extract:** hex color values, components, expo-haptics refs, ReaderTheme type.

---

## 5. Mobile-only primitives

In `apps/mobile/components/ui/`:

| Primitive | Purpose |
|---|---|
| `Sheet` | `@gorhom/bottom-sheet` wrapper with shared defaults (grabber, backdrop, haptic) |
| `Toolbar` | Top/bottom bar with blur + hairline + safe-area |
| `IconButton` | 44pt pressable + hitSlop + haptic + spring scale |
| `Hairline` | `StyleSheet.hairlineWidth` themed divider |
| `PressableScale` | Spring-scale (0.95) pressable wrapper |
| `BookCover` | `expo-image` with rounded corners + format-colored fallback |

Wrap `IconSymbol` inside `IconButton`. `HapticTab` stays in `components/`.

---

## 6. Conflicts and risks

### C1 — `ReaderToolbar` single-bar API incompatible with Phase 3 split
Current component has 16 props, all in top bar. Phase 3 needs top+bottom split. Affects 4 reader screens. Mitigation: keep old version alive during transition; `ReaderShell` wraps both new bars; swap reader-by-reader.

### C2 — NativeWind Tailwind colors vs semantic tokens
Components use `text-gray-900`, `bg-gray-100` directly. Two color systems will coexist during migration. Mitigation: gradual migration, keep NativeWind running.

### C3 — `AppearanceSheet` font-size is % (for epub.js), not pt
Don't conflate with chrome type scale.

### C4 — `expo-blur` not installed
Requires native rebuild. Phase 2 ships `rgba(255,255,255,0.95)` placeholder; real blur in Phase 3 with new EAS build.

### C5 — 6 reader sheets lack backdrop
Phase 2 `Sheet` primitive provides backdrop by default. Refactor each reader sheet to use it. Detox tests must pass before+after.

### C6 — Reader theme system uses raw hex
Extend type with optional `blurTint?` (additive). Don't break.

### C7 — No react-native-skia for Phase 4
Try Reanimated worklets first. Skia only if pure-JS approach looks bad.

---

## 7. Recommended structure (Option B)

Mobile-local tokens. Only orb-colors extracted to shared.

```
packages/shared/src/tokens/
  orb-colors.ts          — AIChatOrb status→color map

apps/mobile/lib/theme/
  tokens.ts              — semantic colors (light+dark), spacing, type scale, motion
  useTheme.ts            — hook reading useColorScheme + AccessibilityInfo
  index.ts               — barrel

apps/mobile/components/ui/
  Sheet.tsx
  Toolbar.tsx
  IconButton.tsx
  Hairline.tsx
  PressableScale.tsx
  BookCover.tsx
  SegmentedControl.tsx (added per designer's spec)
  SearchBar.tsx          (added per designer's spec)
  ListRow.tsx            (added per designer's spec)
  EmptyState.tsx         (added per designer's spec)
  index.ts               — barrel
```

Token values match designer's UI-SPEC.md §1-6 exactly.

---

## Essential Files Reference

### Mobile
- `apps/mobile/constants/theme.ts` — existing tokens
- `apps/mobile/constants/reader-themes.ts` — reader-specific
- `apps/mobile/tailwind.config.js` — empty
- `apps/mobile/app/_layout.tsx` — ThemeProvider root
- `apps/mobile/components/ReaderToolbar.tsx` — to be split in Phase 3
- `apps/mobile/components/AppearanceSheet.tsx`, `TocSheet.tsx`, `HighlightsSheet.tsx` — sheets to refactor
- `apps/mobile/components/auth/PremiumFeatureSheet.tsx` — reference (correct backdrop + haptics)
- `apps/mobile/components/RealtimeVoiceButton.tsx`, `VoiceMicButton.tsx` — Reanimated worklet examples
- `apps/mobile/components/ui/icon-symbol.tsx` — wrap inside new IconButton
- `apps/mobile/types/book.ts` — ReaderTheme types
- `apps/mobile/package.json` — RN 0.81.5, Reanimated 4.1.1, bottom-sheet 5.2.8
- `apps/mobile/app.json` — no expo-blur plugin

### Electron (reference)
- `apps/rishi-electron/src/renderer/src/styles/globals.css` — Tailwind v4 oklch
- `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx` — glass orb canonical
- `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx` — orb-to-pill morph

### New deps required
- `expo-blur` (for Phase 3 toolbar blur — Phase 2 stub allows it)
