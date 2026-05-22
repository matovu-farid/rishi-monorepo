# Phase 2 — Design System Foundation: TESTS.md

Date: 2026-05-22
Author: tester agent (red phase)
Status: Failing tests committed. Coder follows.

---

## 1. Test files written

All files are in TDD red phase — they fail because the production modules
they import do not yet exist. The failing reason is uniform:

- Shared: `Cannot find module '../orb-colors'`
- Mobile: `Could not locate module @/lib/theme/...` or `@/components/ui/...`

This is the expected red signal per the prompt.

### Shared (vitest)

| File | # tests | Pinned behaviour |
|---|---|---|
| `/Users/faridmatovu/projects/rishi-monorepo/packages/shared/src/tokens/__tests__/orb-colors.test.ts` | 4 | 4 status keys present (`idle, connecting, thinking, speaking`); every value matches `/^rgba?\(/i`; sentinel rgba strings match electron `AIChatOrb.tsx` (`'rgba(88, 86, 214, 0.70)'` etc.); `AIChatOrbStatus` type exported and exhaustive |

### Mobile (jest)

| File | # tests | Pinned behaviour |
|---|---|---|
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/lib/theme/tokens.test.ts` | 12 | light/dark palette top-level keys match; nested keys mirror across palettes; every color is non-empty string; `accent.primary` sentinels (`#0a7ea4` / `#3AB4D6`); 12 spacing keys monotonically increasing; `radius.md === 10`, `radius.full ≥ 9999`; typography sentinels (`display-large.fontSize === 34`, `body.fontSize === 17`, `caption-small.fontSize === 11`); weight tokens; `motion.spring.gentle.damping` is a number; `motion.duration.fast === 150`; `shadow.low.shadowOpacity === 0.06`; `shadow.flat.shadowOpacity === 0` |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/lib/theme/useTheme.test.ts` | 5 | scheme=light → `colors.accent.primary === '#0a7ea4'`; scheme=dark → `'#3AB4D6'`; `reduceMotion` defaults boolean false; flipping `AccessibilityInfo.reduceMotionChanged` listener flips `reduceMotion`; memoized return value is referentially stable across renders |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/Sheet.test.tsx` | 4 | `isOpen=false` ⇒ title text not rendered; `isOpen=true` ⇒ title visible; `onChange(-1)` ⇒ `onClose()` called once; children rendered inside the sheet body when open |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/IconButton.test.tsx` | 5 | `onPress` fires on tap; `accessibilityLabel` reflects `label` prop; `Haptics.selectionAsync` fires by default; explicit `haptic="selection"` fires `selectionAsync`; default `hitSlop` inflates a 22pt icon to ≥ 44pt touch target |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/Hairline.test.tsx` | 4 | horizontal: `height === StyleSheet.hairlineWidth`; vertical: `width === StyleSheet.hairlineWidth`; custom `color` prop overrides default `backgroundColor`; `accessible={false}` (decorative) |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/PressableScale.test.tsx` | 5 | renders children; `onPress` fires on tap; shared value reaches `0.95` on pressIn; shared value returns to `1` on pressOut; under `reduceMotion=true` the scale stays at `1` (opacity path takes over) |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/BookCover.test.tsx` | 7 | `uri` provided ⇒ renders `<Image>` from expo-image; missing `uri` ⇒ first letter of title as fallback; fallback color is deterministic per title (same title ⇒ same colour); `size='sm'` → 48pt, `size='md'` → 96pt, `size='lg'` → 144pt (UI-SPEC §7f); `accessibilityRole="image"` + label includes title |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/SegmentedControl.test.tsx` | 4 | every option label rendered; tapping a non-selected segment fires `onChange(value)`; selected segment carries `accessibilityState.selected=true`; non-selected segment carries `accessibilityState.selected=false` |
| `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/__tests__/components/ui/ListRow.test.tsx` | 5 | renders `title`; renders `subtitle` when provided; `accessory='chevron'` renders an Ionicons `chevron-forward`; `onPress` provided ⇒ row is pressable + onPress fires; `accessory={{ kind: 'custom', node }}` renders the custom node |

Total new tests: **55** (4 shared + 51 mobile).

### Tests deferred to Phase 3 (per ARCH §6 / prompt)

- `SearchBar.test.tsx` — cancel-animation needs focus events + animated layout; Detox in Phase 3.
- `EmptyState.test.tsx` — best tested when `LibraryEmptyState` migrates to use it; screenshot-critic in Phase 3.
- `Toolbar.test.tsx` — blur/safe-area is simulator-only; Phase 3 reader-shell context.

This deferral is by-design and confirmed by the architect's playbook (ARCH §6.5).

---

## 2. Mocks added

Each mobile test file mocks the minimum surface to keep the test VM under Node:

| Module | Mock strategy | Used in |
|---|---|---|
| `react-native` | host-element stubs (`View`, `Text`, `Pressable`, `Switch`); `Platform.OS='ios'` + working `Platform.select`; `StyleSheet.create`/`hairlineWidth`; `useColorScheme` (per-file scheme); `AccessibilityInfo.isReduceMotionEnabled` + `addEventListener` capturing the `reduceMotionChanged` listener | every mobile test |
| `react-native-reanimated` | `useSharedValue` returns `{ value }`; `withSpring`/`withTiming` lift the target value through synchronously; `useAnimatedStyle` evaluates the callback; `Animated.View` is a forwardRef passthrough | Sheet, IconButton, PressableScale, SegmentedControl, ListRow |
| `react-native-safe-area-context` | `useSafeAreaInsets` returns fixed `{top:44, bottom:34}`; `SafeAreaProvider` is identity | Sheet, IconButton |
| `@gorhom/bottom-sheet` | passthrough `BottomSheet` capturing the latest `onChange` prop on a module-scoped variable; `BottomSheetBackdrop`, `BottomSheetView`, `BottomSheetScrollView` are inline host nodes; children render only when `index >= 0` | Sheet |
| `@expo/vector-icons` + `@expo/vector-icons/Ionicons` | Renders an `Ionicons` host element carrying `name` + `testID="ion-${name}"` | IconButton, ListRow |
| `expo-haptics` | spies on `selectionAsync`/`impactAsync`/`notificationAsync`; enums declared as strings | IconButton, SegmentedControl, Sheet (noop), ListRow (noop) |
| `expo-image` | `Image` is a host `ExpoImage` node carrying `testID="expo-image"` | BookCover |

The shared vitest file needs no mocks — it imports a pure-data module.

The Reanimated mock per-file follows the same shape as the existing
`PremiumFeatureSheet.test.tsx` convention; we did not install
`react-native-reanimated/mock` globally to keep the diff additive
and predictable, per ARCH §6.1.

---

## 3. Run results

### `pnpm -C packages/shared test`

```
Test Files  1 failed | 35 passed (36)
     Tests  492 passed (492)
```

The single failed suite is `src/tokens/__tests__/orb-colors.test.ts`
failing at import time with
`Cannot find module '../orb-colors'` — the expected red signal.
All 492 pre-existing tests stay green.

### `pnpm -C apps/mobile test` (via `npx jest`)

```
Test Suites: 12 failed, 78 passed, 90 total
Tests:       548 passed, 548 total
```

The 12 failed suites:
- 9 new red-phase suites (this PR): `tokens.test.ts`, `useTheme.test.ts`,
  `Sheet.test.tsx`, `IconButton.test.tsx`, `Hairline.test.tsx`,
  `PressableScale.test.tsx`, `BookCover.test.tsx`,
  `SegmentedControl.test.tsx`, `ListRow.test.tsx`.
- 3 pre-existing baseline failures (NOT this PR): `book-import/file-import.test.ts`,
  `book-import/url-import.test.ts`, `vector.test.ts`. These match the
  current-state document and are explicitly out of scope per the prompt.

Every new suite fails at suite-load time with
`Could not locate module @/lib/theme/...` or `@/components/ui/...` —
the expected red signal. **All 548 pre-existing tests remain green;
no new flake or regression introduced.**

### `pnpm -C apps/rishi-electron typecheck`

```
> tsc --noEmit -p tsconfig.node.json --composite false
> tsc --noEmit -p tsconfig.web.json --composite false
(no diagnostics emitted)
```

Clean. Electron is untouched; the shared package change is purely
additive (a new directory; no `index.ts` mutation in red phase).

---

## 4. Expected pass-after-implementation

The following implementation work (matching ARCH §1-§5) green-fies each
test file:

| Test file | Files the coder must create to turn it green |
|---|---|
| `packages/shared/src/tokens/__tests__/orb-colors.test.ts` | `packages/shared/src/tokens/orb-colors.ts` exporting `ORB_COLORS` (record with `idle/connecting/thinking/speaking` keys, spaced-rgba values transcribed from `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx` L30-41) + `AIChatOrbStatus` type |
| `apps/mobile/__tests__/lib/theme/tokens.test.ts` | `apps/mobile/lib/theme/colors.ts` (colorsLight, colorsDark) + `tokens.ts` (spacing, radius, motion, shadow) + `typography.ts` (typography scale) — colors must mirror keys across palettes, spacing monotonic, typography sentinels match iOS HIG |
| `apps/mobile/__tests__/lib/theme/useTheme.test.ts` | `apps/mobile/lib/theme/useTheme.ts` reading `useColorScheme()` + `AccessibilityInfo.isReduceMotionEnabled` with `addEventListener('reduceMotionChanged', ...)`; returns a `useMemo`-stable `Theme` object |
| `apps/mobile/__tests__/components/ui/Sheet.test.tsx` | `apps/mobile/components/ui/Sheet.tsx` wrapping `@gorhom/bottom-sheet`'s plain `BottomSheet` with imperative `expand()`/`close()` driven by `isOpen`, `onChange(-1)` ⇒ `onClose()`, title row rendered when open |
| `apps/mobile/__tests__/components/ui/IconButton.test.tsx` | `apps/mobile/components/ui/IconButton.tsx` rendering `PressableScale` + Ionicons; `Haptics.selectionAsync()` on press (default); `accessibilityLabel` from `label` prop; default `hitSlop` ≥ 11pt on each side for a 22pt icon. **Note for coder:** the test pins the UI-SPEC §10.3 ≥44pt rule, so `hitSlop` default must inflate accordingly — adjust from ARCH §3c's `8` to `≥11` (or use `{top:11,bottom:11,left:11,right:11}`) so the test passes |
| `apps/mobile/__tests__/components/ui/Hairline.test.tsx` | `apps/mobile/components/ui/Hairline.tsx` — plain `<View>` with `StyleSheet.hairlineWidth` on `height` (horizontal) or `width` (vertical), `backgroundColor` from theme or `color` prop, `accessible={false}` |
| `apps/mobile/__tests__/components/ui/PressableScale.test.tsx` | `apps/mobile/components/ui/PressableScale.tsx` — Reanimated `useSharedValue(1)` for scale; `onPressIn` writes `0.95` (via `withSpring`); `onPressOut` writes `1`; reduceMotion path keeps scale at `1` and animates an opacity shared value instead |
| `apps/mobile/__tests__/components/ui/BookCover.test.tsx` | `apps/mobile/components/ui/BookCover.tsx` rendering `expo-image`'s `Image` when `uri`; deterministic letter fallback (`title[0].toUpperCase()` over a hashed background color); width map sm=48 / md=96 / lg=144 per UI-SPEC §7f; `accessibilityRole="image"` + `accessibilityLabel='Cover of ${title}'` |
| `apps/mobile/__tests__/components/ui/SegmentedControl.test.tsx` | `apps/mobile/components/ui/SegmentedControl.tsx` — Pressable per option with `accessibilityState={{ selected: option.value === value }}`; press calls `onChange(option.value)` |
| `apps/mobile/__tests__/components/ui/ListRow.test.tsx` | `apps/mobile/components/ui/ListRow.tsx` — title (Text), optional subtitle (Text), chevron Ionicons when `accessory='chevron'`, custom accessory render-through, wraps in `PressableScale` when `onPress` set |

After the coder ships the implementation files, the full mobile suite
should reach **548 + 51 = 599 passing tests** (with 3 pre-existing failures
unchanged), and shared should reach **492 + 4 = 496 passing tests**.

---

## 5. Notes / drift the coder should resolve

A few items where the prompt, UI-SPEC, and ARCH disagree. The tests
follow the **prompt verbatim** (it is the canonical task spec); the
coder/architect should reconcile in the green phase:

1. **`motion.duration.fast === 150`** — the prompt pins 150ms; UI-SPEC §5
   and ARCH §1.4 use `motion.timing.fast: { duration: 200 }`. The tests
   read `motion.duration.fast` (the prompt's shape, NOT
   `motion.timing.fast.duration`). The coder must either:
   - expose `motion.duration.fast = 150` alongside `motion.timing.fast`, or
   - rename `motion.timing.fast` to `motion.duration.fast` and drop the
     150 vs 200 discrepancy.

2. **IconButton `hitSlop` default** — the prompt requires ≥ 44pt touch
   target around a 22pt icon (so each side ≥ 11pt). ARCH §3c documents
   the default as `8`. The coder should raise the default to satisfy
   accessibility (UI-SPEC §10.3 already requires this).

3. **`spacing` keys** — the prompt offers two valid shapes (`'1'..'12'`
   OR `1..12` numeric). Tests assert the UI-SPEC §3 t-shirt-size keys
   (`none, xxs, xs, sm, md, lg, xl, 2xl, 3xl, 4xl, 5xl, 6xl`), which is
   a third equally valid option that aligns with ARCH §1.4. If the
   coder ships numeric keys instead, the tester will revisit.

4. **BookCover sizes** — the prompt mentions `sm ~ 64×96`, `md ~ 80×120`,
   `lg ~ 120×180` "or whatever ARCH/UI-SPEC §7 says". UI-SPEC §7f and
   ARCH §3f pin `sm=48`, `md=96`, `lg=144` — the tests assert those.

5. **BookCover "PDF tint"** — the prompt mentions a "format='pdf'"
   tint, but neither UI-SPEC §7f nor ARCH §3f wire a per-format tint;
   they hash `title`. The test verifies "fallback is deterministic per
   title" instead of pinning a PDF-specific colour. If the coder
   decides to add a `format` prop with per-format tints, the test
   remains green (deterministic-per-title is still satisfied) and a
   follow-up red can pin specific PDF hues.

6. **ORB rgba string spacing** — the prompt and the electron source
   both use spaced rgba (`'rgba(88, 86, 214, 0.70)'`). ARCH §2.2
   transcribes them without spaces. Tests assert the spaced form.
   The coder must use the spaced form to match the electron source
   verbatim (which is the whole point of extracting the constant).

These are notes for the green phase, not blockers for the red commit.

---

End of TESTS.md.
