# Phase 4 — Floating Widgets: ARCH.md

Date: 2026-05-22
Author: architect agent
Status: Ready for tester (red) and coder (green)

---

## Resolved decisions

- **OQ1 GlassDisk primitive**: YES. Extract to `apps/mobile/components/ui/GlassDisk.tsx`.
- **OQ2 Morph anchor**: `width + transform: translateX`. Orb stays `right: 16`; pill translates left by `(screenWidth/2 - 16 - pillWidth/2)`.
- **OQ3 Auto-collapse on scroll**: NO. Timer only.
- **OQ4 playerStore.repeatMode**: Add `repeatMode: 'off' | 'one'` + `setRepeatMode`. Phase 4 button is visual toggle; loop is Phase 5.
- **OQ5 Tab bar offset**: constant 49 for Phase 4; dynamic `useBottomTabBarHeight()` deferred to Phase 6.
- **OQ6 AIChatOrb tint**: 24% alpha overlay using ORB_COLORS RGB triples.
- **OQ7 Drag-to-reposition**: deferred to Phase 5.

---

## Verified code facts

- TTSControls mounted in 4 readers: `[id].tsx:667`, `pdf/[id].tsx:606`, `mobi/[id].tsx:491`, `djvu/[id].tsx:421`
- `ReaderShell` renders children → ReaderTopBar → ReaderBottomBar → sheets. Mount ReaderOverlay after ReaderBottomBar
- `chatStore`: `isChatting`, `chatStatus`, `voiceState`, `startChat(bookId: number)`, `stopConversation()`. No `toggleChatPanel` — chat nav owned by reader (`router.push('/chat/${id}')`)
- `voiceActive` derived: `voiceState === 'active' || 'listening' || 'speaking'`
- `useBottomTabBarHeight()` crashes outside tab navigator — use constant 49
- `stringToNumberID` needed to convert string bookId → number for `chatStore.startChat`
- All Phase 2 primitives are camelCase props + `useTheme()` + `reduceMotion` branch — match this pattern
- Reanimated pattern reference: `RealtimeVoiceButton.tsx:24-47` (useSharedValue + useAnimatedStyle + useEffect[status])
- `@expo/vector-icons`, `expo-blur` (~15.0.8), `expo-haptics`, `react-native-reanimated` (~4.1.1), `@gorhom/bottom-sheet` (^5.2.8) all installed
- `react-native-skia` NOT installed (don't add)

---

## Risk verification

- **R1 z-index**: Sheets use portal — orbs at z 20 sit below. No collision. Action: none.
- **R2 perf**: 6 useSharedValue per orb, 1 per launcher, 5 per MiniPlayer. All worklets. reduceMotion bypass. Pattern matches RealtimeVoiceButton.
- **R3 gesture**: Pressable consumes 52×52 tap. No hitSlop. No Gesture.Pan needed.
- **R4 MMKV drag**: deferred.
- **R5 tab bar**: constant 49.
- **R6 position**: `bottom: insets.bottom + 112, left: 32` for AIChatOrb; mirror at right for VoiceChatLauncher.

---

## 1. GlassDisk — `apps/mobile/components/ui/GlassDisk.tsx`

```ts
export interface GlassDiskProps {
  size: number
  tintColor?: string
  children?: ReactNode
  testID?: string
  style?: ViewStyle
}
```

Two-View render tree (shadows don't survive `overflow:'hidden'` on iOS):

```
<View style={[shadow.medium, style]}>                          // outer: shadow + position
  <View style={{ width:size, height:size, borderRadius:size/2, overflow:'hidden' }}>
    <BlurView intensity={80} tint={scheme==='dark'?'systemMaterialDark':'systemMaterial'} 
              style={StyleSheet.absoluteFill} accessible={false} />
    {tintColor ? <View style={[absoluteFill, {backgroundColor:tintColor}]} 
                       pointerEvents="none" accessible={false} /> : null}
    <View style={{position:'absolute', inset:0, borderRadius:size/2,
                  borderWidth:StyleSheet.hairlineWidth,
                  borderColor: scheme==='dark'?'rgba(255,255,255,0.18)':'rgba(255,255,255,0.45)'}}
          pointerEvents="none" accessible={false} />
    {children}
  </View>
</View>
```

Export from `apps/mobile/components/ui/index.ts`.

Tests: renders BlurView, applies size, applies testID, conditional tint, conditional default color.

---

## 2. AIChatOrb — `apps/mobile/components/chat/AIChatOrb.tsx`

```ts
export interface AIChatOrbProps {
  chatStatus: AIChatOrbStatus  // from @rishi/shared/tokens/orb-colors
  onPress: () => void
  style?: ViewStyle
  testID?: string  // default 'ai-chat-orb'
}
```

Shared values: bar0Scale, bar1Scale, bar2Scale, bar3Scale (init 1.0), ringScale (init 0.9), ringOpacity (init 0).

ORB_TINTS (24% alpha overlay):
```ts
const ORB_TINTS: Record<AIChatOrbStatus, string> = {
  idle:       'rgba(88,86,214,0.24)',
  connecting: 'rgba(59,130,246,0.24)',
  thinking:   'rgba(251,191,36,0.24)',
  speaking:   'rgba(34,197,94,0.24)',
}
```

`useEffect[chatStatus, reduceMotion]`:
1. cancelAnimation all 6
2. idle or reduceMotion: bars to 1.0 (or 0.7 reduceMotion), ringOpacity 0
3. speaking (half 300ms, stagger 150): per-bar `withDelay(i*150, withRepeat(withSequence(withTiming(0.4,{dur:300}), withTiming(1,{dur:300})), -1, true))`
4. thinking (half 400ms, stagger 200): same scaleY + per-bar opacity (500ms half)
5. connecting (half 350ms, stagger 150): same scaleY + ringScale 0.9↔1.15 (dur 700), ringOpacity 0.3↔0.7 (dur 700)

Connecting indicator (reduceMotion fallback): 6×6 absolute View top-right, blue background.

Pulse ring: sibling Animated.View outside GlassDisk clip, `top:-2 left:-2`, 56×56, border 2pt `rgba(59,130,246,0.6)`.

Bars: heights `[8,14,20,12]`, width 3, gap 3, radius 1.5, `flexDirection:'row' alignItems:'center'`.

Accessibility:
```ts
const A11Y_LABELS = { idle:'AI chat', connecting:'AI chat — connecting',
                      thinking:'AI chat — thinking', speaking:'AI chat — speaking' }
```
Role button, hint "Toggle the chat panel".

---

## 3. VoiceChatLauncher — `apps/mobile/components/chat/VoiceChatLauncher.tsx`

```ts
export interface VoiceChatLauncherProps {
  isActive: boolean
  onStart: () => void
  onStop: () => void
  style?: ViewStyle
  testID?: string  // default 'voice-chat-launcher'
}
```

Shared value: breathScale (init 1.0).

`useEffect[isActive, reduceMotion]`:
- isActive || reduceMotion: cancelAnimation; `breathScale = withSpring(1, motion.spring.snappy)`
- else: `withRepeat(withSequence(withTiming(1,{dur:1000,easing:Easing.inOut(Easing.quad)}), withTiming(1.04,{dur:1000,easing:Easing.inOut(Easing.quad)})), -1, true)`

Press: `Haptics.selectionAsync()`; `isActive ? onStop() : onStart()`.

Icon: Ionicons `mic-outline`/`mic-off-outline`, 22pt, `colors.label.primary` opacity 0.6.

Accessibility:
- isActive=false: label "Start voice chat", hint "Begin a real-time voice conversation about this book"
- isActive=true: label "Stop voice chat", hint "End the voice conversation"

---

## 4. MiniPlayer — `apps/mobile/components/player/MiniPlayer.tsx`

```ts
export interface MiniPlayerProps {
  bookId?: string
  variant?: 'reader' | 'global'  // default 'reader'
  tabBarHeight?: number          // default 49 (global only)
  testID?: string                // default 'mini-player'
}
```

Shared values: expandedValue (init 0), bar0..bar3 (init 1.0).

Internal state: `expanded`, `collapseTimerRef`.

Bottom offset:
```ts
const insets = useSafeAreaInsets()
const { bottomBarVisible } = useContext(ReaderShellContext)
const resolvedTabBarHeight = variant === 'global' ? (tabBarHeight ?? 49) : 0
const bottomOffset = variant === 'reader'
  ? insets.bottom + 16 + (expanded ? 0 : (bottomBarVisible ? 44 : 0))
  : insets.bottom + 16 + resolvedTabBarHeight
```

Morph container:
```ts
const { width: screenWidth } = useWindowDimensions()
const pillWidth = repeatMode !== 'off' ? 280 : 240
const containerStyle = useAnimatedStyle(() => {
  const w = interpolate(expandedValue.value, [0,1], [52, pillWidth], Extrapolation.CLAMP)
  const h = interpolate(expandedValue.value, [0,1], [52, 66], Extrapolation.CLAMP)
  const r = interpolate(expandedValue.value, [0,1], [26, 40], Extrapolation.CLAMP)
  const tx = interpolate(expandedValue.value, [0,1],
    [0, -((screenWidth/2) - 16 - pillWidth/2)], Extrapolation.CLAMP)
  return { width: w, height: h, borderRadius: r, transform: [{ translateX: tx }] }
})
```

Outer Animated.View: `position:'absolute', bottom:bottomOffset, right:16, zIndex:20`.

Cross-fade orb/pill via opacity `1 - expandedValue.value` and `expandedValue.value`. Both inside the morphing container.

Bars animate when `playingState === 'playing'`: half-period 150ms, stagger 100ms.

Auto-collapse `useEffect[playingState, expanded]`: if expanded && !playing, 4000ms timer → collapse. Reset on control press.

`if (playingState === 'idle' || !send) return null`.

Pill order: Prev | Play-Pause | Repeat (when `repeatMode !== 'off'`, FadeIn/Out) | Next | Stop.

isLoading: `playingState === 'loading' || 'waitingForParagraphs' || 'pageNavigating'` → ActivityIndicator instead of icon.

---

## 5. ReaderOverlay — `apps/mobile/components/reader/ReaderOverlay.tsx`

```ts
export interface ReaderOverlayProps {
  bookId?: string
  onChatToggle?: () => void
  testID?: string  // default 'reader-overlay'
}
```

```ts
const isChatting = useChatStore(s => s.isChatting)
const chatStatus = useChatStore(s => s.chatStatus)
const voiceState = useChatStore(s => s.voiceState)
const startChat = useChatStore(s => s.startChat)
const stopConversation = useChatStore(s => s.stopConversation)
const playingState = usePlayerStore(s => s.playingState)
const requireVoiceChat = useRequireAuth('voice-chat')
const voiceActive = voiceState === 'active' || voiceState === 'listening' || voiceState === 'speaking'
const handleVoiceStart = useCallback(() => {
  requireVoiceChat(() => { if (bookId) startChat(stringToNumberID(bookId)) })
}, [requireVoiceChat, startChat, bookId])
```

Render:
```tsx
<View testID={testID ?? 'reader-overlay'} pointerEvents="box-none" style={StyleSheet.absoluteFill}>
  {isChatting ? (
    <AIChatOrb chatStatus={chatStatus} onPress={onChatToggle ?? (() => {})}
               style={{ position:'absolute', bottom:insets.bottom+112, left:32, zIndex:20 }} />
  ) : null}
  <VoiceChatLauncher
    isActive={voiceActive}
    onStart={handleVoiceStart}
    onStop={stopConversation}
    style={{ position:'absolute', bottom:insets.bottom+112, right:32, zIndex:20 }}
  />
  {!isChatting && playingState !== 'idle'
    ? <MiniPlayer bookId={bookId} variant="reader" />
    : null}
</View>
```

---

## 6. GlobalMiniPlayer — `apps/mobile/components/player/GlobalMiniPlayer.tsx`

```ts
export function GlobalMiniPlayer(): React.JSX.Element | null {
  const pathname = usePathname()
  const playingState = usePlayerStore(s => s.playingState)
  if (pathname?.startsWith('/reader')) return null
  if (playingState === 'idle') return null
  return <MiniPlayer variant="global" tabBarHeight={49} testID="global-mini-player" />
}
```

---

## 7. playerStore additions

`apps/mobile/lib/stores/playerStore.ts`:

```ts
export type RepeatMode = 'off' | 'one'
// add to interface:
repeatMode: RepeatMode
setRepeatMode: (mode: RepeatMode) => void
// initial state:
repeatMode: 'off',
// action:
setRepeatMode: (mode) => set({ repeatMode: mode }),
```

---

## 8. ReaderShell modification

Add to `ReaderShellProps`:
```ts
bookId?: string
onChatToggle?: () => void
```

Add to function param destructuring.

Add import: `import { ReaderOverlay } from '@/components/reader/ReaderOverlay'`

Mount in render after `<ReaderBottomBar>`:
```tsx
<ReaderOverlay bookId={bookId} onChatToggle={onChatToggle} />
```

---

## 9. Reader screen updates

For each of `[id].tsx`, `pdf/[id].tsx`, `mobi/[id].tsx`, `djvu/[id].tsx`:
- Remove `import { TTSControls } from '@/components/TTSControls'`
- Add `bookId={book.id}` (or `book?.id`) to `<ReaderShell>` invocation
- EPUB also: `onChatToggle={() => requireAIChat(() => router.push(\`/chat/${book.id}\`))}`
- Remove `<TTSControls />` JSX

Then DELETE `apps/mobile/components/TTSControls.tsx`.

Verify: `grep -r 'TTSControls' apps/mobile/` → zero (excluding git history).

---

## 10. `_layout.tsx` modification

Add import: `import { GlobalMiniPlayer } from '@/components/player/GlobalMiniPlayer'`

Insert `<GlobalMiniPlayer />` after `<Slot />` in BOTH render branches (E2E branch line ~202, normal branch line ~215).

---

## 11. Test surface

Mock blocks: react-native, react-native-reanimated (with shared-value capture), expo-blur, expo-haptics, react-native-safe-area-context, `@rishi/shared/tokens/orb-colors`.

Test files:
- `__tests__/components/ui/GlassDisk.test.tsx` — 5 tests
- `__tests__/components/chat/AIChatOrb.test.tsx` — 7 tests
- `__tests__/components/chat/VoiceChatLauncher.test.tsx` — 6 tests
- `__tests__/components/player/MiniPlayer.test.tsx` — 12 tests
- `__tests__/components/reader/ReaderOverlay.test.tsx` — 8 tests
- `__tests__/components/player/GlobalMiniPlayer.test.tsx` — 6 tests

Total: 44 new test cases.

---

## 12. Build sequence

```
Stage A: GlassDisk primitive
  Commit: feat(mobile/ui): GlassDisk primitive for glass-morphism circles

Stage B: AIChatOrb
  Commit: feat(mobile/chat): AIChatOrb with Reanimated 3 waveform

Stage C: VoiceChatLauncher
  Commit: feat(mobile/chat): VoiceChatLauncher with breathing animation

Stage D: playerStore repeatMode + MiniPlayer
  Commit: feat(mobile/player): MiniPlayer with orb-to-pill morph

Stage E: ReaderOverlay orchestrator
  Commit: feat(mobile/reader): ReaderOverlay orchestrates floating widgets

Stage F: Mount ReaderOverlay in ReaderShell + reader screens pass bookId
  Commit: feat(mobile): ReaderShell mounts ReaderOverlay

Stage G: Delete TTSControls
  Commit: refactor(mobile): delete TTSControls (replaced by MiniPlayer)

Stage H: GlobalMiniPlayer in _layout.tsx
  Commit: feat(mobile/player): GlobalMiniPlayer persists across navigation
```

Each stage: tests + typecheck pass before commit.

---

## 13. Done-when

- [ ] GlassDisk, AIChatOrb, VoiceChatLauncher, MiniPlayer, ReaderOverlay, GlobalMiniPlayer all exist
- [ ] playerStore has repeatMode
- [ ] TTSControls.tsx deleted; grep returns zero refs
- [ ] 4 reader screens cleaned; bookId passed to ReaderShell
- [ ] ReaderShell mounts ReaderOverlay
- [ ] _layout.tsx mounts GlobalMiniPlayer (both branches)
- [ ] 44 new tests + 618 baseline = ≥662 passing
- [ ] Mobile + electron typecheck clean
