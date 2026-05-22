# Phase 4 — Floating Widgets: TESTS.md

Date: 2026-05-22
Author: tester agent
Mode: TDD red phase (Mode A)

---

## Summary

6 test files written. 44 total test cases. All 6 suites fail at module
import time with `Could not locate module @/components/...` — the
expected red signal per ARCH §11.

No existing tests were modified. Baseline suites (`ReaderShell`,
`ReaderProgressPill`, `PremiumFeatureSheet`, `IconButton`) still pass:
25/25.

---

## Per-file

### 1. `apps/mobile/__tests__/components/ui/GlassDisk.test.tsx` — 5 tests

What's verified (against `@/components/ui/GlassDisk`):

- Renders a `BlurView` host node in the tree.
- Inner clip container's style has both `width` and `height` equal to the
  `size` prop.
- `testID` prop appears on a node in the rendered tree.
- When `tintColor` is provided, a `<View>` exists whose `backgroundColor`
  is the tint color.
- When `tintColor` is omitted, NO view in the tree carries any of the 4
  ORB_TINTS background colors.

Red signal: `Could not locate module @/components/ui/GlassDisk`.

### 2. `apps/mobile/__tests__/components/chat/AIChatOrb.test.tsx` — 7 tests

What's verified (against `@/components/chat/AIChatOrb`):

- Renders the root (default `testID='ai-chat-orb'`) for each of the 4
  statuses (`idle | connecting | thinking | speaking`).
- `accessibilityLabel` matches the A11Y_LABELS map per status.
- Pressing the orb invokes the `onPress` prop.
- Pulse ring `testID='ai-chat-orb-ring'` is ABSENT in `idle`, `thinking`,
  `speaking`.
- Pulse ring is PRESENT in `connecting`.
- Default `testID='ai-chat-orb'` when no `testID` prop is supplied.
- Custom `testID` prop overrides the default (default is no longer in tree).

Red signal: `Could not locate module @/components/chat/AIChatOrb`.

### 3. `apps/mobile/__tests__/components/chat/VoiceChatLauncher.test.tsx` — 6 tests

What's verified (against `@/components/chat/VoiceChatLauncher`):

- Renders Ionicons `mic-outline` when `isActive=false` and not `mic-off-outline`.
- Renders Ionicons `mic-off-outline` when `isActive=true` and not `mic-outline`.
- Press with `isActive=false` invokes `onStart` (and not `onStop`).
- Press with `isActive=true` invokes `onStop` (and not `onStart`).
- Default `testID='voice-chat-launcher'`.
- `breathScale` shared-value pattern is present: `useSharedValue(1)` is
  called at least once during render (loose check; doesn't pin the
  specific animation chain).

Red signal: `Could not locate module @/components/chat/VoiceChatLauncher`.

### 4. `apps/mobile/__tests__/components/player/MiniPlayer.test.tsx` — 12 tests

What's verified (against `@/components/player/MiniPlayer`):

- Returns `null` when `playingState='idle'`.
- Returns `null` when `playerStore.send` is `null`.
- Renders with `testID='mini-player'` when playing.
- `testID='mini-player-orb'` present initially (expanded=false).
- Tapping `mini-player-orb` reveals `testID='mini-player-pill'`.
- Press play-pause while `playingState='playing'` → `send({type:'PAUSE'})`.
- Press play-pause while `playingState='paused.clean'` → `send({type:'RESUME'})`.
- Press `mini-player-next` → `send({type:'NEXT'})`.
- Press `mini-player-prev` → `send({type:'PREV'})`.
- Press `mini-player-stop` → `send({type:'STOP'})`.
- ActivityIndicator renders in play-pause slot when `playingState='loading'`.
- Repeat button absent when `repeatMode='off'`, present when `repeatMode='one'`.

Red signal: `Could not locate module @/components/player/MiniPlayer`.

### 5. `apps/mobile/__tests__/components/reader/ReaderOverlay.test.tsx` — 8 tests

What's verified (against `@/components/reader/ReaderOverlay`):

- Root has `testID='reader-overlay'`.
- `AIChatOrb` stub mounted when `isChatting=true`.
- `AIChatOrb` stub absent when `isChatting=false`.
- `VoiceChatLauncher` stub ALWAYS mounted (true for both
  `(false, idle)` and `(true, playing)`).
- `MiniPlayer` stub mounted when `!isChatting && playingState='playing'`.
- `MiniPlayer` stub absent when `isChatting=true && playingState='playing'`.
- `MiniPlayer` stub absent when `playingState='idle'`.
- `onChatToggle` prop is forwarded to AIChatOrb's `onPress`.

Per ARCH §11 the 3 child widgets are stubbed (`AIChatOrb`,
`VoiceChatLauncher`, `MiniPlayer`) so the suite asserts on the props
ReaderOverlay forwards rather than re-running each widget's own behaviour.

Red signal: `Could not locate module @/components/reader/ReaderOverlay`.

### 6. `apps/mobile/__tests__/components/player/GlobalMiniPlayer.test.tsx` — 6 tests

What's verified (against `@/components/player/GlobalMiniPlayer`):

- Returns `null` when `pathname='/reader/abc'`.
- Returns `null` when `pathname='/reader/some/nested'`.
- Returns `null` when `pathname='/(tabs)/index'` but `playingState='idle'`.
- Renders MiniPlayer stub when `pathname='/(tabs)/index'` and `playingState='playing'`.
- MiniPlayer stub receives `testID='global-mini-player'`.
- MiniPlayer stub receives `variant='global'` prop.

Red signal: `Could not locate module @/components/player/GlobalMiniPlayer`.

---

## Mock infra added (consistent across all 6 suites)

Each suite (where relevant) installs:

- `react-native` — host-tag stubs for `View`, `Text`, `Pressable`,
  `TouchableOpacity`, `ActivityIndicator`; `useColorScheme: () => 'light'`;
  `useWindowDimensions` (MiniPlayer only — 390×844 / scale 3 / fontScale 1);
  `StyleSheet.absoluteFill` / `absoluteFillObject` / `hairlineWidth` /
  `Platform.select`.
- `react-native-safe-area-context` — `useSafeAreaInsets()` returning
  either `{top:0,bottom:0}` (primitives) or `{top:44,bottom:34}` (reader
  context tests).
- `react-native-reanimated` — host `Animated.View`, shared-value capture
  (`useSharedValue(v) → { value: v }`), passthrough `withTiming` /
  `withSpring` / `withDelay` / `withSequence` / `withRepeat`, `Easing`
  stub, `interpolate` passthrough, `Extrapolation.CLAMP`, `FadeIn` /
  `FadeOut` / `SlideInDown` / `SlideOutDown` stubs where used.
  VoiceChatLauncher's suite additionally captures all `useSharedValue`
  initial values into a module-scoped `sharedValueInits` array so the
  breathScale pattern can be asserted loosely.
- `expo-blur` — `BlurView` host node with `testID='blur-view'`.
- `expo-haptics` — `selectionAsync` / `impactAsync` / `notificationAsync`
  jest mocks + enum stubs.
- `@expo/vector-icons` + `@expo/vector-icons/Ionicons` — Ionicons rendered
  as host node with `testID={`ion-${name}`}`.
- `@rishi/shared/tokens/orb-colors` — literal ORB_COLORS map (matches
  the Phase 2 source of truth verbatim).
- `@/components/ui/GlassDisk` — stubbed to a host node with
  `testID='glass-disk'` for AIChatOrb / VoiceChatLauncher / MiniPlayer
  suites. Declared with `{ virtual: true }` so the mock can be installed
  even before the GlassDisk source lands; the moduleNameMapper rewrite
  still surfaces the "Cannot find module" red signal at jest.mock
  hoist time, which is the desired pre-green state.
- `@/lib/stores/playerStore` (MiniPlayer / ReaderOverlay /
  GlobalMiniPlayer) — selector-mock pattern with a reassignable
  module-scoped `playerState` so each test can drive `playingState`,
  `send`, `repeatMode` independently.
- `@/lib/stores/chatStore` (ReaderOverlay) — selector-mock with
  reassignable `chatState` (`isChatting`, `chatStatus`, `voiceState`,
  `startChat`, `stopConversation`).
- `@/components/auth/useRequireAuth` — passthrough that immediately
  invokes the action (no premium gate inside the unit).
- `@/components/reader/ReaderShell` (MiniPlayer) — exports a fresh
  `ReaderShellContext` so MiniPlayer can `useContext` without dragging
  in the real shell.
- `expo-router` (GlobalMiniPlayer) — `usePathname` returning a
  reassignable `pathnameValue`; `useRouter` / `Slot` / `Stack` stubs.
- For ReaderOverlay: the 3 child widget paths (`@/components/chat/AIChatOrb`,
  `@/components/chat/VoiceChatLauncher`, `@/components/player/MiniPlayer`)
  are stubbed `{ virtual: true }` to host nodes that capture props.

---

## Verification run

```
$ pnpm exec jest --testPathPatterns \
    "components/(ui/GlassDisk|chat/(AIChatOrb|VoiceChatLauncher)|player/(MiniPlayer|GlobalMiniPlayer)|reader/ReaderOverlay)"

FAIL __tests__/components/ui/GlassDisk.test.tsx
FAIL __tests__/components/chat/AIChatOrb.test.tsx
FAIL __tests__/components/chat/VoiceChatLauncher.test.tsx
FAIL __tests__/components/player/MiniPlayer.test.tsx
FAIL __tests__/components/player/GlobalMiniPlayer.test.tsx
FAIL __tests__/components/reader/ReaderOverlay.test.tsx

Test Suites: 6 failed, 6 total
Tests:       0 total
```

Each failure cites `Could not locate module @/components/...` — the
target SUT module does not exist yet. This is the exact red signal ARC §11
expects before Stages A–H of the build sequence land.

Baseline regression check (sample): `ReaderShell`, `ReaderProgressPill`,
`PremiumFeatureSheet`, `IconButton` → 25/25 still passing.

---

## Next step

Hand off to the coder for Stages A–H. Once each stage lands, the
corresponding suite should flip from "Cannot find module" to passing
without modification — the tests pin observable behaviour, not
implementation internals.
