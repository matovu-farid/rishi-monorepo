# Phase 4 — Floating Widgets (UI-SPEC)

Date: 2026-05-22
Status: Designer spec — input for the architect's file plan
Scope: `AIChatOrb`, `VoiceChatLauncher`, `MiniPlayer` (orb + pill), `ReaderOverlay` orchestrator, `GlobalMiniPlayer`. Glass morphism recipe, position rules, motion, haptics, a11y, and migration plan.

Design philosophy: Apple-Books-style glass — calm, translucent surfaces that float over the reader without competing with text. Apple Maps / iPadOS 17 control aesthetic for the glass disks. Motion is springy-but-quiet, never bouncy. Honor reduce-motion across the board.

Inputs honored:
- `.parity-v2/phase4-floating-widgets/RESEARCH.md` (electron reference, mount strategy, Reanimated decision)
- `.parity-v2/phase2-design-system/UI-SPEC.md` (tokens: motion springs, shadows, expo-blur recipe)
- Electron source: `AIChatOrb.tsx`, `VoiceChatLauncher.tsx`, `TTSControls.tsx`, `ReaderOverlayControls.tsx`
- Shared tokens: `packages/shared/src/tokens/orb-colors.ts`

Dep policy: **no new deps**. Everything resolves with `expo-blur` (Phase 2), `react-native-reanimated@~4.1.1`, `react-native-gesture-handler@~2.28`, `react-native-mmkv@^4.3.1`, `expo-haptics`, `@expo/vector-icons` (Ionicons).

---

## 1. AIChatOrb (mobile)

### 1.1 Visual

- **Frame**: 52×52 pt, `borderRadius: 26` (= `radius.full` clamped to circle), `overflow: 'hidden'`. Wrapped with `shadow.medium`.
- **Surface**: glass disk per Section 4 recipe. Tint colors come from `ORB_COLORS` via a thin colored fill **above** the BlurView (24% alpha) so the tint reads as the orb's identity without losing the frosted feel.
- **Bars**: 4 vertical bars, all transform-only animated (cheap on the UI thread):
  | Bar | Width | Height | Gap | Radius |
  |---|---|---|---|---|
  | 1–4 | 3pt | `[8, 14, 20, 12]` pt | 3pt | 1.5pt |
  - Horizontal centering: the bars row uses `flexDirection: 'row'` + `alignItems: 'center'` so bars vertically center on their tallest sibling.
  - `transformOrigin: 'center'` for scaleY.
  - Bar fill color = `ORB_COLORS[status]`.

### 1.2 States (`ChatStatus = 'idle' | 'connecting' | 'thinking' | 'speaking'`)

Bar color, ring, and animation differ per status. Source of truth: `packages/shared/src/tokens/orb-colors.ts`.

| Status | Bar color | Bar animation | Ring |
|---|---|---|---|
| `idle` | `rgba(88,86,214,0.70)` (purple) | static at `scaleY: 1.0` | none |
| `connecting` | `rgba(59,130,246,0.80)` (blue) | scaleY 0.4↔1.0, 700ms, stagger 150ms/bar | pulse ring (see below) |
| `thinking` | `rgba(251,191,36,0.80)` (amber) | scaleY 0.6↔1.0 + opacity 0.5↔1.0, 800ms, stagger 200ms/bar | none |
| `speaking` | `rgba(34,197,94,0.80)` (green) | scaleY 0.4↔1.0, 600ms, stagger 150ms/bar | none |

### 1.3 Pulse ring (connecting only)

- Absolute child, **outside** the clipped disk (so the ring extends past the 52pt frame).
- Size 56×56, `borderRadius: 28`, `borderWidth: 2`, `borderColor: 'rgba(59,130,246,0.6)'`, `position: 'absolute'`, centered with negative inset (`top: -2, left: -2`).
- Animation: `scale` 0.9↔1.15 + `opacity` 0.7↔0.3, `withRepeat(withTiming(.., 1400ms), -1, true)` (reverse).

### 1.4 Bar animation (Reanimated 4)

Single shared timing per bar (no per-frame JS):

```ts
// Pseudocode for the architect
const scaleY = useSharedValue(1);
useEffect(() => {
  if (reduceMotion || status === 'idle') {
    scaleY.value = reduceMotion ? 0.7 : 1.0;
    return;
  }
  scaleY.value = withDelay(
    barIndex * staggerMs,
    withRepeat(
      withSequence(
        withTiming(0.4, { duration: halfPeriod }),
        withTiming(1.0, { duration: halfPeriod }),
      ),
      -1,
      true,
    ),
  );
}, [status, reduceMotion]);
```

Stagger and period come from the table in §1.2.

### 1.5 Position

```ts
{
  position: 'absolute',
  bottom: insets.bottom + 96 + 16,  // = 112 + insets.bottom (mirrors VoiceChatLauncher)
  left: 32,
  zIndex: 20,
}
```

Mirror of `VoiceChatLauncher`'s right-side anchor. Electron's "screen-center" position is rejected — it would block book content on mobile.

### 1.6 Interaction

- **Mount condition**: `isChatting === true` (from `chatStore`).
- **Tap**: calls `onPress` (parent toggles chat panel). Haptic: `Haptics.selectionAsync()`.
- **Long-press** (Phase 5 if shipped): begins drag — see §6.

### 1.7 Reduce-motion fallback

- Bars set to `scaleY: 0.7` static, no `withRepeat`.
- No ring (even in connecting state — replace with a 2pt opaque blue dot in the top-right of the disk to signal "connecting").
- No tint pulse.

### 1.8 Props

```ts
type AIChatOrbProps = {
  status: 'idle' | 'connecting' | 'thinking' | 'speaking';
  onPress: () => void;
  testID?: string;          // default: 'ai-chat-orb'
};
```

No size prop — orb size is fixed at 52pt per electron parity.

---

## 2. VoiceChatLauncher (mobile)

### 2.1 Visual

- 52×52 pt glass disk per Section 4 recipe (no tint overlay — neutral surface).
- **Icon**: `<Ionicons name={isActive ? 'mic-off-outline' : 'mic-outline'} size={22} color={colors.label.primary} style={{ opacity: 0.6 }} />`.
- `shadow.medium` wrap.

### 2.2 Position

```ts
{
  position: 'absolute',
  bottom: insets.bottom + 96 + 16,  // = 112 + insets.bottom
  right: 32,
  zIndex: 20,
}
```

### 2.3 Idle breathing animation

Subtle, only when **not active**:

```ts
scale.value = withRepeat(
  withSequence(
    withTiming(1.0,  { duration: 1000, easing: Easing.inOut(Easing.quad) }),
    withTiming(1.04, { duration: 1000, easing: Easing.inOut(Easing.quad) }),
  ),
  -1,
  true,
);
```

Stops when `isActive === true` — at that moment the orb settles to scale 1.0 with `withSpring(motion.spring.snappy)` and stays static until inactive again.

### 2.4 Press animation

Wrap in `<PressableScale scale={0.95} hitSlop={8}>` from Phase 2 primitives. No icon swap mid-press.

### 2.5 Mount

**Always** mounted on the reader screen (inside `<ReaderOverlay>` — never floats over Library / Chat / Settings tabs).

### 2.6 Interaction

```ts
onPress = () => {
  Haptics.selectionAsync();
  if (isActive) onStop();                                         // Stop voice chat immediately
  else requireAuth('voice-chat', () => onStart());                // Auth gate matches Phase 1 ladder
};
```

`requireAuth` is the Phase 1 helper that either calls the action (if authed) or opens the sign-in sheet which continues the action on success.

### 2.7 Reduce-motion fallback

- No breathing (`scale.value = 1.0` static).
- PressableScale falls back to opacity-on-press (handled by Phase 2 primitive).

### 2.8 Props

```ts
type VoiceChatLauncherProps = {
  isActive: boolean;             // from chatStore.voiceState
  onStart: () => void;
  onStop: () => void;
  testID?: string;               // default: 'voice-chat-launcher'
};
```

---

## 3. MiniPlayer (mobile — evolves TTSControls)

Single component with **two visual states** that morph via a shared spring-animated value. Replaces the current `apps/mobile/components/TTSControls.tsx` (which is a plain dark pill — no glass, no orb).

### 3.1 Orb state (collapsed)

- 52×52 pt glass disk (Section 4).
- 4-bar waveform identical geometry to `AIChatOrb` (heights `[8,14,20,12]`).
- Bar color:
  - Light: `rgba(0,0,0,0.50)`
  - Dark: `rgba(255,255,255,0.50)`
- Bars animate **only** when `playingState === 'playing'` (300ms half-period, stagger 100ms/bar — slower than chat orb so it reads as "audio playback" not "thinking AI").
- **Position**:
  ```ts
  {
    position: 'absolute',
    bottom: insets.bottom + 16 + (bottomBarVisible ? 44 : 0),
    right: 16,
    zIndex: 20,
  }
  ```
- **Tap**: expand to pill. Haptic: `Haptics.impactAsync(ImpactFeedbackStyle.Soft)`.

### 3.2 Pill state (expanded)

- **Size**:
  - No repeat: width 240pt
  - With repeat (per-paragraph repeat enabled): width 280pt
  - Height: 66pt
  - `borderRadius: 40`
- **Position**: centered horizontally, anchored bottom:
  ```ts
  {
    position: 'absolute',
    bottom: insets.bottom + 16,
    left: '50%',
    transform: [{ translateX: -width / 2 }],
    zIndex: 20,
  }
  ```
- **Contents** (row, `gap: 8`, `paddingHorizontal: 12`):
  1. `Prev` — IconButton `play-skip-back`
  2. `Play/Pause` — IconButton `play` / `pause`; on `playingState === 'loading'`, render `<ActivityIndicator size="small" />` in place of the icon
  3. `Repeat` — IconButton `repeat` (only when `repeatMode !== 'off'`), mounted via Reanimated `Layout`/`FadeIn` so it animates in when toggled on
  4. `Next` — IconButton `play-skip-forward`
  5. `Stop` — IconButton `stop`
- Each control: tap target 44×44pt (visual 32pt centered), uses `<PressableScale scale={0.95}>` from Phase 2, haptic `selection`.
- **Auto-collapse**: 4000ms timer; resets on any control press or on `playingState` transition to `playing` (active playback prevents collapse). Collapse skipped while finger interaction is detected via `onPressIn`.

### 3.3 Morph (orb ↔ pill)

Single `Animated.View` reads from one shared value `expandedValue: 0 | 1`:

```ts
const expandedValue = useSharedValue(0);
// On tap orb → toggle:
expandedValue.value = withSpring(expandedValue.value > 0.5 ? 0 : 1, motion.spring.snappy);
// motion.spring.snappy = { damping: 22, stiffness: 400, mass: 1 }
```

Animated style interpolates:

| Property | Orb (0) | Pill (1, no repeat) | Pill (1, with repeat) |
|---|---|---|---|
| width | 52 | 240 | 280 |
| height | 52 | 66 | 66 |
| borderRadius | 26 | 40 | 40 |
| right (anchor) | 16 | n/a — switch to centered | n/a |

Anchor switch: rather than animating `right` to a center value (which fights `translateX`), the morph keeps `right: 16` during collapse and uses a single `translateX` interpolation:

```ts
// At expandedValue=0: translateX = 0 (orb anchored right:16)
// At expandedValue=1: translateX = -((screenWidth/2) - (16 + width/2))
//                    (moves left so the pill ends centered)
```

The architect can choose to animate `left/right/transform` directly — the visual outcome is what matters. Recommended single-`Animated.View` with interpolated `width` + `transform: translateX` (simpler).

**Inner content cross-fade**: bars (`opacity: 1 - expandedValue`) fade out while pill controls (`opacity: expandedValue`) fade in. Both share the same parent so no remount on morph.

**Reduce-motion**: replace `withSpring` with `withTiming(value, motion.timing.normal)`. Bars/controls cross-fade still uses opacity timing.

### 3.4 Two instances (reader vs global)

| Instance | Mount point | Gating |
|---|---|---|
| Reader-mounted `<MiniPlayer>` | Inside `<ReaderOverlay>` (which lives inside `<ReaderShell>` children) | Mounted whenever on a reader screen; visible only when `playingState !== 'idle'`; **hidden when `isChatting`** (matches electron `display:none` pattern) |
| Global `<GlobalMiniPlayer>` | Root layout `app/_layout.tsx` (outside the `(tabs)` group) | Gated on `!pathname.startsWith('/reader') && playingState !== 'idle'` |

Reader-mounted instance always takes priority. Global instance never renders when a reader screen is focused (avoids dual-render visual stack).

Both instances read the same `playerStore` and `repeatMode` selector — pressing controls on either mutates the same store, so a song that's paused on the library tab stays paused when entering the reader.

### 3.5 Props

```ts
type MiniPlayerProps = {
  bookId: string;                        // reader-mounted: from route; global: from playerStore.activeBookId
  variant?: 'reader' | 'global';         // default: 'reader' — controls bottom-offset calc
  testID?: string;                       // default: 'mini-player'
};
```

Internal state (not props): `expanded: boolean`, `expandedValue: SharedValue<number>`, auto-collapse timer ref.

---

## 4. Glass morphism mobile recipe

RN has no `backdrop-filter`. The visual is composed:

```tsx
// Phase 2 had no glass component — Phase 4 introduces the recipe inline.
// Architect may extract to `components/ui/GlassDisk.tsx` if it appears 3+ times.

<View
  style={[
    {
      borderRadius,
      overflow: 'hidden',
      backgroundColor: scheme === 'dark' ? 'rgba(0,0,0,0.25)' : 'rgba(255,255,255,0.25)',
    },
    shadow.medium,
  ]}
>
  <BlurView
    intensity={80}
    tint={scheme === 'dark' ? 'systemMaterialDark' : 'systemMaterial'}
    style={StyleSheet.absoluteFill}
  />
  {/* Optional tint overlay (AIChatOrb only — uses ORB_COLORS[status] at 24% alpha) */}
  {tintColor ? (
    <View
      style={[StyleSheet.absoluteFill, { backgroundColor: tintColor }]}
      pointerEvents="none"
    />
  ) : null}
  {/* Inner hairline border for the iOS-Books "glass edge" */}
  <View
    style={{
      position: 'absolute',
      top: 0, left: 0, right: 0, bottom: 0,
      borderRadius,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: scheme === 'dark' ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.45)',
    }}
    pointerEvents="none"
  />
  {children}
</View>
```

Notes:
- `BlurView` `tint` accepts the iOS UIVisualEffectStyle name; `systemMaterial` ≈ adaptive frosted glass that picks light/dark automatically — but we still pass the dark variant explicitly so Android (which uses a JS fallback) renders the correct fallback color.
- `intensity={80}` matches Phase 2's `glass.intensity` token. Architect may read it via `useTheme().glass.intensity` once Phase 2's theme has a `glass` field exported (Phase 2 §6.2 says it should).
- `overflow: 'hidden'` clips the BlurView to the rounded shape. **Do not** put it on parent — the rounded clip must be on the same View as the BlurView so iOS doesn't show square corners.
- Android (no native UIBlurEffect): expo-blur renders an experimental implementation. The `backgroundColor` of the wrapper (`rgba(255,255,255,0.25)` light / `rgba(0,0,0,0.25)` dark) is the **fallback** if blur fails — it must remain legible-with-bars-on-top on its own.

---

## 5. Position table

| Widget | Bottom offset | Horizontal | zIndex |
|---|---|---|---|
| AIChatOrb | `insets.bottom + 112` | `left: 32` | 20 |
| VoiceChatLauncher | `insets.bottom + 112` | `right: 32` | 20 |
| MiniPlayer orb | `insets.bottom + 16 + (bottomBarVisible ? 44 : 0)` | `right: 16` | 20 |
| MiniPlayer pill | `insets.bottom + 16` | centered (`left: 50%`, `translateX(-width/2)`) | 20 |

z-stack reference (lowest → highest):
- 0 — Book content (`<ReaderEngine>`)
- 10 — `ReaderTopBar`, `ReaderBottomBar`
- 11 — `GuardrailWarning`
- 20 — **All floating widgets** (AIChatOrb, VoiceChatLauncher, MiniPlayer)
- portal — `@gorhom/bottom-sheet` modals (always above)

**When a sheet opens** (TOC, Appearance, etc.): orbs remain at z 20; sheets at portal z sit above. If user reports "orbs poking through sheets" during QA, the architect's escape hatch is `ReaderShellContext.anySheetOpen → orbs hide`. Not implemented in Phase 4 by default — verified visually first.

---

## 6. Drag-to-reposition (DEFERRED to Phase 5)

Recommended approach if/when shipped:

```ts
const tx = useSharedValue(initialX);
const ty = useSharedValue(initialY);

const pan = Gesture.Pan()
  .activateAfterLongPress(300)             // requires 300ms long-press to begin drag
  .onChange((e) => {
    tx.value = clamp(tx.value + e.changeX, 16, screenWidth - 52 - 16);
    ty.value = clamp(ty.value + e.changeY, insets.top + 16, screenHeight - insets.bottom - 52 - 16);
  })
  .onEnd(() => {
    runOnJS(saveToMMKV)({ x: tx.value, y: ty.value });
  });
```

- Persist per-widget: `mmkv.set('orb-pos-aichat', JSON.stringify({x,y}))` (and similar for `orb-pos-voice`, `orb-pos-miniplayer`).
- Hydrate on mount; if missing, fall back to default positions from §5.
- Long-press haptic: `Haptics.impactAsync(Medium)` to signal "drag mode active".

**Decision**: Phase 4 ships with **fixed positions only**. Drag is Phase 5 polish; if it's blocking ship, defer to Phase 6.

---

## 7. Haptics

| Action | Haptic |
|---|---|
| Tap AIChatOrb | `Haptics.selectionAsync()` |
| Tap VoiceChatLauncher (start) | `Haptics.selectionAsync()` |
| Tap VoiceChatLauncher (stop) | `Haptics.selectionAsync()` |
| Tap MiniPlayer orb (expand) | `Haptics.impactAsync(Soft)` |
| Tap MiniPlayer pill control (any) | `Haptics.selectionAsync()` |
| MiniPlayer auto-collapse | none (silent) |
| Long-press orb to start drag (Phase 5) | `Haptics.impactAsync(Medium)` |
| Drag-snap to safe-area edge (Phase 5) | `Haptics.selectionAsync()` |

Haptic suppression: if `useTheme().reduceMotion === true`, skip all haptics (Phase 2 baseline §10).

---

## 8. Accessibility

All orbs are buttons. All have **type-required** `accessibilityLabel`:

| Widget | accessibilityRole | accessibilityLabel | accessibilityHint |
|---|---|---|---|
| AIChatOrb (idle) | button | `"AI chat"` | `"Toggle the chat panel"` |
| AIChatOrb (connecting) | button | `"AI chat — connecting"` | `"Toggle the chat panel"` |
| AIChatOrb (thinking) | button | `"AI chat — thinking"` | `"Toggle the chat panel"` |
| AIChatOrb (speaking) | button | `"AI chat — speaking"` | `"Toggle the chat panel"` |
| VoiceChatLauncher (idle) | button | `"Start voice chat"` | `"Begin a real-time voice conversation about this book"` |
| VoiceChatLauncher (active) | button | `"Stop voice chat"` | `"End the voice conversation"` |
| MiniPlayer orb | button | `"Audio playing — tap to expand"` (or `"Audio paused — tap to expand"` when paused) | `"Open the playback controls"` |
| MiniPlayer pill Prev | button | `"Previous paragraph"` | — |
| MiniPlayer pill Play | button | `"Play"` (when paused) / `"Pause"` (when playing) | — |
| MiniPlayer pill Repeat | button | `"Repeat paragraph"` / `"Repeat off"` | — |
| MiniPlayer pill Next | button | `"Next paragraph"` | — |
| MiniPlayer pill Stop | button | `"Stop playback"` | — |

Decorative children (bars, ring, BlurView fill) are `accessible={false}`.

Reader content under the orbs remains in the VoiceOver rotor unchanged — orbs do **not** set `accessibilityViewIsModal`.

Touch targets: minimum 44×44pt. Orbs are 52×52 → meets. Pill icon buttons are 32×32 visual + 6pt hitSlop each side = 44×44 effective.

---

## 9. State coordination

### 9.1 ReaderOverlay component (new)

`apps/mobile/components/reader/ReaderOverlay.tsx` — pure orchestrator, no business logic:

```tsx
type ReaderOverlayProps = {
  bookId: string;
};

export function ReaderOverlay({ bookId }: ReaderOverlayProps) {
  const isChatting   = useChatStore(s => s.isChatting);
  const chatStatus   = useChatStore(s => s.chatStatus);
  const voiceActive  = useChatStore(s => s.voiceState === 'active');
  const playingState = usePlayerStore(s => s.playingState);

  const onChatToggle = useChatStore(s => s.toggleChatPanel);
  const onVoiceStart = useChatStore(s => s.startVoiceChat);
  const onVoiceStop  = useChatStore(s => s.stopConversation);

  return (
    <>
      {isChatting ? (
        <AIChatOrb status={chatStatus} onPress={onChatToggle} />
      ) : null}

      <VoiceChatLauncher
        isActive={voiceActive}
        onStart={onVoiceStart}
        onStop={onVoiceStop}
      />

      {/* MiniPlayer hidden when chatting (matches electron display:none) */}
      {!isChatting && playingState !== 'idle' ? (
        <MiniPlayer bookId={bookId} variant="reader" />
      ) : null}
    </>
  );
}
```

### 9.2 Mount sequence in ReaderShell

Single new line inside `<ReaderShell>` children, just below `<ReaderEngine>`:

```tsx
<ReaderEngine ... />
<ReaderOverlay bookId={bookId} />   {/* NEW */}
<GuardrailWarning ... />
<UndoSnackbar ... />
<AnnotationPopover ... />
{/* TTSControls REMOVED — superseded by MiniPlayer inside ReaderOverlay */}
```

### 9.3 GlobalMiniPlayer (new)

`apps/mobile/components/GlobalMiniPlayer.tsx` — mounted once at root layout:

```tsx
// apps/mobile/app/_layout.tsx — add near the top-level providers
export default function RootLayout() {
  // ...existing providers...
  return (
    <Stack>{/* ... */}</Stack>
    <GlobalMiniPlayer />   {/* NEW */}
  );
}

function GlobalMiniPlayer() {
  const pathname = usePathname();
  const playingState = usePlayerStore(s => s.playingState);
  const activeBookId = usePlayerStore(s => s.activeBookId);
  if (pathname?.startsWith('/reader')) return null;
  if (playingState === 'idle' || !activeBookId) return null;
  return <MiniPlayer bookId={activeBookId} variant="global" />;
}
```

The `variant='global'` only affects bottom offset (no `bottomBarVisible` context outside reader — assume 0; account for tab bar height ~49pt by adding to the base offset).

### 9.4 State matrix

| `isChatting` | `voiceActive` | `playingState` | AIChatOrb | VoiceChatLauncher | MiniPlayer |
|---|---|---|---|---|---|
| false | false | idle | hidden | mounted (idle icon, breathing) | hidden |
| false | false | playing/paused/loading | hidden | mounted (idle, breathing) | orb (or pill if user-expanded) |
| false | true | idle | hidden | mounted (active icon, no breathing) | hidden |
| false | true | playing | hidden | mounted (active) | orb |
| true | false | playing | shown (status from chatStore) | mounted (idle, breathing) | **hidden** |
| true | true | playing | shown | mounted (active) | **hidden** |

When `isChatting` flips false → true while playback is active: MiniPlayer unmounts but `playerStore.playingState` is preserved (matches electron — audio keeps playing under the hood; only the visual is hidden). The mount/unmount cycle should not pause playback because the player is a store-side side-effect, not coupled to MiniPlayer lifecycle.

---

## 10. Migration plan

Phase 4 ships in 8 stages. Each is its own TDD red→green commit; reviewer signs off before next stage starts.

| Stage | Work | Tests required |
|---|---|---|
| 1 | Build `AIChatOrb` component (+ glass disk helper if extracted) | render in each of 4 states, fires `onPress`, reduce-motion fallback, testID |
| 2 | Build `VoiceChatLauncher` component | renders mic icon, fires onStart/onStop, breathing stops when active, auth-gate calls `requireAuth('voice-chat', start)` |
| 3 | Evolve `TTSControls` → `MiniPlayer` (orb + pill morph) | orb renders when playing, tap expands to pill, controls dispatch correct player actions, ActivityIndicator on loading, auto-collapse after 4000ms idle, repeat button conditional |
| 4 | Build `ReaderOverlay` orchestrator | mounts correct widgets per state matrix (§9.4), hides MiniPlayer when chatting, passes bookId/onPress through |
| 5 | Mount `<ReaderOverlay>` inside `<ReaderShell>` children + remove standalone TTSControls | snapshot the 5 reader formats (EPUB/PDF/MOBI/DJVU/AZW3); none regress |
| 6 | Wire `bookId` + `chatStatus` from ReaderShell → ReaderOverlay | bookId comes from route; chat state comes from store (already global) |
| 7 | Build `GlobalMiniPlayer` (root layout) | not rendered on `/reader/*`; rendered when playingState != idle; tab-bar offset correct |
| 8 | Manual verification + screenshot all 5 reader formats with: chrome hidden, chrome shown, chatting, playing | screenshots committed to `.parity-v2/phase4-floating-widgets/screenshots/` |

Out of scope for Phase 4 (deferred to Phase 5/6):
- Drag-to-reposition (§6)
- Per-format animation perf tuning beyond reduce-motion check
- Custom Android blur fallback styling (we use the rgba background fallback)

---

## 11. ASCII mockups

### 11.1 Reader screen — chrome hidden, all 3 widgets visible

```
+--------------------------------------------------+
|                                                  |
|     The Great Gatsby                             |
|                                                  |
|     In my younger and more vulnerable years      |
|     my father gave me some advice that I've      |
|     been turning over in my mind ever since.     |
|                                                  |
|     "Whenever you feel like criticizing any      |
|     one," he told me, "just remember that all    |
|     the people in this world haven't had the     |
|     advantages that you've had."                 |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|     ╔═══════╗                  ╔═══════╗         |  ← AIChatOrb (left)  + VoiceChatLauncher (right)
|     ║|::I|::║                  ║   🎤  ║         |     (only shown if isChatting; voice always)
|     ╚═══════╝                  ╚═══════╝         |
|                                                  |
|                              ╔═══════╗           |  ← MiniPlayer orb
|                              ║|:I:|: ║           |     (right edge, above safe-area)
|                              ╚═══════╝           |
|                                                  |
+--------------------------------------------------+
```

### 11.2 Reader screen — chrome shown, widgets shifted up

```
+--------------------------------------------------+
|  ‹ Back        The Great Gatsby            ⋯    |  ← ReaderTopBar (z:10)
|--------------------------------------------------|
|                                                  |
|     In my younger and more vulnerable years      |
|     my father gave me some advice...             |
|                                                  |
|                                                  |
|                                                  |
|                                                  |
|     ╔═══════╗                  ╔═══════╗         |  ← Orbs (same bottom offset; far enough up
|     ║|::I|::║                  ║   🎤  ║         |     to clear the bottom bar)
|     ╚═══════╝                  ╚═══════╝         |
|                                                  |
|                              ╔═══════╗           |  ← MiniPlayer orb
|                              ║|:I:|: ║           |     shifted UP by +44 (bottomBarVisible)
|                              ╚═══════╝           |
|--------------------------------------------------|
|  TOC   Annot.   Highlights   Search        Aa  |  ← ReaderBottomBar (z:10)
+--------------------------------------------------+
```

### 11.3 MiniPlayer — orb state

```
            ╔═══════╗
            ║  ▎▎▎▎ ║    ← 4 bars, [8,14,20,12] heights, animated when playing
            ╚═══════╝
            52 × 52 pt
            radius full
            glass disk
```

### 11.4 MiniPlayer — pill state (no repeat = 240pt)

```
       ┌──────────────────────────────────────┐
       │    ⏮      ▶/⏸       ⏭       ⏹      │   ← Prev, Play/Pause, Next, Stop
       └──────────────────────────────────────┘
                  240 × 66 pt   radius 40
                  centered, bottom: insets.bottom + 16
```

### 11.5 MiniPlayer — pill state (with repeat = 280pt)

```
       ┌──────────────────────────────────────────────┐
       │   ⏮     ▶/⏸     🔁     ⏭     ⏹            │   ← Prev, Play/Pause, Repeat, Next, Stop
       └──────────────────────────────────────────────┘
                       280 × 66 pt   radius 40
```

### 11.6 Chatting state — AIChatOrb shown, MiniPlayer hidden

```
+--------------------------------------------------+
|                                                  |
|     [book content]                               |
|                                                  |
|                                                  |
|                              ┌─────────────────┐ |
|                              │  Chat panel     │ |
|                              │  (existing UI)  │ |
|                              │                 │ |
|                              └─────────────────┘ |
|                                                  |
|     ╔═══════╗                  ╔═══════╗         |  ← AIChatOrb visible (status-tinted)
|     ║|::I|::║                  ║   🎤  ║         |     VoiceChatLauncher visible
|     ╚═══════╝                  ╚═══════╝         |
|                                                  |
|              [NO MiniPlayer — hidden]            |  ← Even if playingState !== idle, hidden
|                                                  |
+--------------------------------------------------+
```

### 11.7 Voice chat active — VoiceChatLauncher shows mic-off

```
            ╔═══════╗
            ║  🎤❌  ║   ← mic-off-outline icon, no breathing animation
            ╚═══════╝
```

---

## 12. testIDs

Stable string testIDs, used by e2e (Detox / Maestro) and Phase 4 unit tests:

| testID | Element |
|---|---|
| `ai-chat-orb` | Root view of `<AIChatOrb>` |
| `ai-chat-orb-ring` | Pulse ring (connecting state only) |
| `voice-chat-launcher` | Root view of `<VoiceChatLauncher>` |
| `mini-player` | Root view of `<MiniPlayer>` (always set, whether orb or pill) |
| `mini-player-orb` | Inner element when collapsed (`expanded === false`) |
| `mini-player-pill` | Inner element when expanded (`expanded === true`) |
| `mini-player-play-pause` | Play/Pause button in pill |
| `mini-player-prev` | Previous button in pill |
| `mini-player-next` | Next button in pill |
| `mini-player-stop` | Stop button in pill |
| `mini-player-repeat` | Repeat button in pill (when mounted) |
| `reader-overlay` | Root fragment of `<ReaderOverlay>` (architect: wrap in `<View testID>` purely for query target) |
| `global-mini-player` | Root of `<GlobalMiniPlayer>` wrapper |

Convention: lowercase-hyphen, no per-status suffix on AIChatOrb — status is read off `accessibilityLabel` instead.

---

## 13. Open questions for the architect

1. **Glass disk extraction** — recipe in §4 appears in all 3 widgets. Extract to `components/ui/GlassDisk.tsx` (Phase 2-style primitive) **OR** inline 3 times? Recommendation: extract — single source of truth for blur intensity / tint / hairline / shadow. The primitive accepts `size`, `tintColor?`, `children`, `testID`.

2. **MiniPlayer morph anchor strategy** — animate `width` + `transform: translateX` (recommended, no layout thrash) vs animate `left/right` directly (cleaner mental model, but causes layout passes). Recommendation: width + translateX.

3. **MiniPlayer auto-collapse during scroll** — should the pill collapse when the user scrolls the reader content? Recommendation: **no**, only collapse on the 4000ms idle timer. Scrolling is too coupled to "I'm reading; please leave my controls in place."

4. **`repeatMode` source** — currently no `repeatMode` exists in mobile `playerStore`. Phase 4 needs to add a `repeatMode: 'off' | 'one'` selector to `playerStore` for the conditional Repeat button. **Action for architect**: add this to ARCH.md as a Phase 4 store change.

5. **GlobalMiniPlayer tab bar offset** — should `variant: 'global'` MiniPlayer offset for the tab bar (49pt + safe-area)? Recommendation: yes. Add: `bottom = insets.bottom + 16 + tabBarHeight` (tabBarHeight = 49 by default on iOS; architect resolves via `useBottomTabBarHeight()` from `@react-navigation/bottom-tabs`).

6. **AIChatOrb tint composition** — Section 1.1 puts a tint overlay above the BlurView at 24% alpha. Visual verification needed: does 24% read correctly for purple-on-frosted-light vs amber-on-frosted-dark? Recommendation: ship at 24%, screenshot all 4 statuses × light/dark = 8 combos in Stage 8, adjust to 20%/28% only if a status reads weakly.

7. **Drag-to-reposition deferred** — confirmed Phase 5 (§6). Architect: do not include drag scaffolding in the Phase 4 PLAN.md; revisit during Phase 5 if needed.

---

## 14. Verification checklist (designer → architect handoff)

- [ ] All 3 widgets specified with: size, color, motion, position, mount condition, props, a11y, reduce-motion fallback
- [ ] Glass recipe is RN-implementable with current deps (expo-blur + Reanimated, no new native modules)
- [ ] State coordination matrix (§9.4) covers `(isChatting, voiceActive, playingState)` exhaustively
- [ ] Migration plan (§10) is 8 atomic stages, each independently testable
- [ ] Position table (§5) anchored to safe-area insets and `bottomBarVisible` context (provided by Phase 3 `ReaderShellContext`)
- [ ] testIDs (§12) are stable strings, used in unit + e2e
- [ ] No new deps required
- [ ] Reduce-motion fallback present for all 3 widgets
- [ ] Haptic table (§7) is complete and honors reduce-motion suppression
- [ ] ASCII mockups (§11) show all 5 requested states

---

End of UI-SPEC. Architect: please produce the file plan in `.parity-v2/phase4-floating-widgets/ARCH.md`. Open questions (§13) should be resolved at the top of ARCH.md before the file plan.
