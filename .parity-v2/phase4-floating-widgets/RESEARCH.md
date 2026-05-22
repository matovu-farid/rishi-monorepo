# Phase 4 — Floating Widgets: RESEARCH.md

Date: 2026-05-22
Author: researcher agent

---

## 1. Electron Reference

### 1.1 AIChatOrb (`apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx`)

**Visual**: 52×52 circle, `borderRadius: '50%'`, `position: fixed`, centered (`top:50% left:50% translate(-50%,-50%)`). Interior: 4 vertical bars 3px wide, gaps 3px, heights `[8,14,20,12]`, `borderRadius:1.5`, `transformOrigin:'center'`.

**Glass morphism (identical across all 3 electron widgets)**:
```
background: linear-gradient(135deg, rgba(255,255,255,0.30), rgba(255,255,255,0.12), rgba(200,210,230,0.16))
backdropFilter: blur(40px) saturate(180%)
border: 1px solid rgba(255,255,255,0.45)
boxShadow: 0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12),
           inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)
```

**States** (`ChatStatus = 'idle'|'connecting'|'thinking'|'speaking'`) — bar colors from `ORB_COLORS` shared:
- idle: purple, bars static
- connecting: blue, `ai-connecting` keyframe + pulse ring
- thinking: amber, `ai-pulse` keyframe
- speaking: green, `ai-waveform` keyframe

**CSS keyframes**:
- `ai-waveform`: 1.2s ease-in-out scaleY 0.4→1→0.4, stagger 0.15s/bar
- `ai-pulse`: 1.6s ease-in-out opacity 0.5→1 + scaleY 0.6→1, stagger 0.2s/bar
- `ai-connecting`: 1.4s ease-in-out scaleY 0.3→1, stagger 0.15s/bar
- `ai-pulse-ring`: connecting only, 56×56 ring, scale 0.9→1.15
- prefers-reduced-motion: near-static

**Interactions**: role="button" + onClick + onKeyDown (Enter/Space). Mount condition: `isChatting === true`.

### 1.2 VoiceChatLauncher

52×52 circle, `position: fixed bottom:96 right:32`. Lucide `<Mic>` (idle) or `<MicOff>` (chatting), color `text-black/60`. Same glass. Tailwind `transition-transform duration-150 hover:scale-105 active:scale-95`. No breathing animation in current electron build (Phase 4 mobile can add it).

Auth gate: `requireAuth('voice-chat', () => setIsChatting(true))` on start; bypass on stop.

Mount: always mounted in ReaderOverlayControls.

### 1.3 TTSControls (electron) — MiniPlayer reference

**Two shapes (morphing)**:

*Collapsed orb*: 52×52, `bottom:32 right:32`. Interior: 4-bar `[8,14,20,12]`; bars animate `tts-waveform` only when `playingState==='playing'`; color `rgba(0,0,0,0.50)`.

*Expanded pill*: width 240/280 (with Repeat), height 66, `borderRadius:40`, `bottom:32 left:50% translateX(-50%)`. Contains: SkipBack / Play-Pause / Repeat (AnimatePresence) / SkipForward / Stop. Buttons use lighter glassButton (`blur(20px)`).

**Morph**: single CSS transition on `width, height, border-radius, padding, gap, bottom, right, left, transform`. Expand 250ms `cubic-bezier(0.34,1.56,0.64,1)`. Collapse 200ms ease-in-out. Auto-collapses 4000ms unless active playback.

**Controls dispatched**: PLAY, PAUSE, RESUME, STOP, NEXT, PREV, REPEAT. Auth gate: only PLAY initial.

### 1.4 ReaderOverlayControls (orchestrator)

```tsx
{isChatting ? <AIChatOrb chatStatus={chatStatus} onClick={onChatOrbClick} /> : null}
<VoiceChatLauncher />
<div style={{ display: isChatting ? 'none' : 'contents' }}>
  <TTSControls bookId={bookId} />
  <TTSVisualCue />
</div>
```

TTSControls hidden via `display:none` while chatting (preserves audio state).

---

## 2. Mobile Current State

### 2.1 TTSControls (mobile, post-Phase 3)
- `position:'absolute'`, `bottom: insets.bottom + 16 + (bottomBarVisible ? 44 : 0)`
- 56pt height, `borderRadius:16`, `rgba(0,0,0,0.8)` — plain dark pill, **no glass**
- Controls: Prev / Play-Pause (ActivityIndicator loading) / Next / Stop
- Progress bar 2pt at bottom
- Enters `SlideInDown.duration(250)`, exits `SlideOutDown.duration(200)`
- Reads `ReaderShellContext.bottomBarVisible` for z-stacking
- Returns null when idle
- **No orb, no morph, no Repeat**
- Mounted inside `<ReaderShell>` children at `app/reader/[id].tsx:667`

### 2.2 RealtimeVoiceButton
NOT a floating widget. 44×44 TouchableOpacity inside ReaderBottomBar action cluster (via `onRealtimePress`). Reanimated 3 already: opacity pulse (active 800ms), scale pulse (speaking 600ms). Icons: phone.fill / waveform.

### 2.3 VoiceMicButton
NOT in scope — 40×40 inside chat text input bar.

### 2.4 ReaderShell mount points
`ReaderShell.tsx` (lines 336-433): `{children}`, `<ReaderTopBar zIndex:10>`, `<ReaderBottomBar zIndex:10>`, 6 conditional sheets. **No floating orbs mounted.**

### 2.5 EPUB reader floating layer
Inside ReaderShell children (lines 639-697): `reader-position-indicator`, `<ReaderEngine>`, `<GuardrailWarning zIndex:11>`, `<TTSControls>`, `<TTSVisualCue>`, `<UndoSnackbar>`, `<AnnotationPopover>`. No AIChatOrb, no VoiceChatLauncher.

---

## 3. Shared State Available

### 3.1 chatStore (mobile)
`apps/mobile/lib/stores/chatStore.ts` — `isChatting`, `chatStatus: ChatStatus`, `voiceState`, `voiceError`, `setIsChatting`, `setChatStatus`, `startChat`, `stopConversation`. `ChatStatus` type-identical to electron. Voice via injectable `VoiceChatPort` interface.

### 3.2 playerStore (mobile)
Port of electron. `playingState: PlayerStoreState` (10 states), `activeParagraph`, `currentParagraphs`, `send: PlayerSend | null`. Missing `lastPlayedParagraphIndex` (intentional, mobile doesn't persist position).

### 3.3 ORB_COLORS (shared)
`packages/shared/src/tokens/orb-colors.ts` already in place from Phase 2. Importable as `@rishi/shared/tokens/orb-colors`.

### 3.4 Motion tokens (mobile)
`useTheme().motion.spring`:
- gentle: `{damping:18, stiffness:250, mass:1}`
- snappy: `{damping:22, stiffness:400, mass:1}` — use for orb→pill morph
- bouncy: `{damping:12, stiffness:200, mass:1}`

Durations: fast 200, normal 300, slow 500.

---

## 4. Reanimated vs Skia Decision

**Decision: Reanimated 3 worklets for all three widgets.**

Confirmed in `apps/mobile/package.json`:
- `react-native-reanimated: ~4.1.1` ✓
- `react-native-worklets: 0.5.1` ✓
- `react-native-skia: NOT installed`

Skia would add ~3MB and require native rebuild. Reanimated suffices for 4 animated rectangles + circle.

**Implementation outline**:

*AIChatOrb waveform*:
```ts
const scales = bars.map(() => useSharedValue(0))
status !== 'idle':
  withRepeat(withSequence(
    withTiming(0.4, { duration: halfPeriod }),
    withTiming(1.0, { duration: halfPeriod }),
  ), -1, false)
// stagger via per-bar delay
```
Periods: speaking 600ms/bar, thinking 800ms/bar, connecting 700ms/bar.

*Connecting pulse ring*: extra `useSharedValue` for ring scale (0.9→1.15) + opacity (0.7→0.3), `withRepeat(withTiming(...), -1, true)`. Absolute view radius 9999.

*VoiceChatLauncher breathing* (enhancement): gentle `withRepeat(withSequence(...), -1, true)` on scale, 2000ms period, only when `!isChatting`.

*MiniPlayer morph*: `useSharedValue(expanded ? 1 : 0)` with `withSpring(motion.spring.snappy)`. Interpolate width [52→240], height [52→66], radius [26→40], translateX from right corner to center.

---

## 5. Mount Strategy

**Recommendation: hybrid split.**

| Widget | Mount point | Rationale |
|---|---|---|
| AIChatOrb | Inside ReaderShell (new `<ReaderOverlay>` child) | Reader-scoped; needs bookId for chat |
| VoiceChatLauncher | Inside ReaderShell | Reader-scoped; book-specific voice chat |
| MiniPlayer (orb) | Root layout `app/_layout.tsx` | Persists across navigation |
| TTSControls (existing) | Keep in reader children | Reader-only playback control; evolve into MiniPlayer orb |

Global MiniPlayer gating:
```ts
const pathname = usePathname()
const playingState = usePlayerStore(s => s.playingState)
const isReaderScreen = pathname.startsWith('/reader')
if (playingState === 'idle' || isReaderScreen) return null
```

z-index allocation in ReaderShell:
- Book content: 0
- TTSControls (existing): unset (stacks naturally)
- GuardrailWarning: 11
- ReaderTopBar/BottomBar: 10
- ReaderOverlay (orbs): 20
- Sheets: portal z (above all)

---

## 6. Existing TTSControls Disposition

**Recommendation: evolve TTSControls into MiniPlayer visual; do not delete.**

Path:
1. Rename TTSControls → MiniPlayer (or create new MiniPlayer.tsx superseding it)
2. Add glass morphism (use expo-blur BlurView per Phase 2 token)
3. Add orb state when `playingState !== 'idle'` — 52×52 with waveform
4. Add morph: tap orb → expanded pill with Prev/Play/Repeat/Next/Stop
5. Position: orb at `bottom: insets.bottom + 16, right: 16`
6. Global instance: `<GlobalMiniPlayer />` at root, gated on route + playingState

Reader-mounted takes priority; GlobalMiniPlayer yields.

---

## 7. Risks

### R1: z-index conflicts
Sheets use BottomSheet portal (high z). Orbs at z 20 should sit below sheets. Verify; if not, reduce to z 9 or hide orbs when any sheet is open via context.

### R2: Animation performance on older devices
Cap to 6 `useSharedValue` per orb. All logic in worklets. Honor `useTheme().reduceMotion` — skip `withRepeat` when true.

### R3: Gesture conflicts with EPUB swipe
EPUB has `enableSwipe={true}`. Orbs at 52×52 with no extra hitSlop should consume taps but pass through swipes. Evaluate `Gesture.Pan().requireToFail()` if needed.

### R4: MMKV drag-position persistence
`react-native-mmkv` and `react-native-gesture-handler` v2.28 both installed. Drag-to-reposition uses `Gesture.Pan().onChange()`. Clamp to safe-area. Defer if blocking — orbs can have fixed positions initially.

### R5: MiniPlayer on tab screens vs tab bar overlap
Tab bar is `position:absolute bottom:0`. Mount GlobalMiniPlayer in root layout (above tab nav) OR offset bottom by tab bar height (~49pt).

### R6: AIChatOrb position
Electron centers it (desktop). Mobile center blocks book content. Recommendation: `bottom: insets.bottom + 96 + 16, left: 32` — mirror of VoiceChatLauncher position.

---

## 8. Essential Files Reference

### Electron reference
- `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx`
- `apps/rishi-electron/src/renderer/src/components/chat/VoiceChatLauncher.tsx`
- `apps/rishi-electron/src/renderer/src/components/tts/TTSControls.tsx`
- `apps/rishi-electron/src/renderer/src/components/reader/ReaderOverlayControls.tsx`
- `apps/rishi-electron/src/renderer/src/stores/chatStore.ts`
- `apps/rishi-electron/src/renderer/src/stores/playerStore.ts`

### Mobile current
- `apps/mobile/components/TTSControls.tsx` — Phase 3 final; MiniPlayer starting point
- `apps/mobile/components/RealtimeVoiceButton.tsx` — Reanimated 3 usage pattern (not floating)
- `apps/mobile/components/reader/ReaderShell.tsx` — Phase 3 ReaderShell, no orbs mounted
- `apps/mobile/components/reader/ReaderBottomBar.tsx` — zIndex 10
- `apps/mobile/app/reader/[id].tsx` — EPUB; TTSControls at line 667
- `apps/mobile/app/_layout.tsx` — root layout; mount point for GlobalMiniPlayer

### Shared
- `packages/shared/src/tokens/orb-colors.ts` — already extracted
- `apps/mobile/lib/stores/chatStore.ts` — ChatStatus + isChatting
- `apps/mobile/lib/stores/playerStore.ts` — playingState
- `apps/mobile/lib/theme/tokens.ts` — motion springs

### Key deps confirmed
- `react-native-reanimated: ~4.1.1` ✓
- `react-native-gesture-handler: ~2.28.0` ✓
- `react-native-mmkv: ^4.3.1` ✓
- `expo-blur: ~15.0.8` ✓ (BlurView for glass)
- `react-native-skia: absent` (use Reanimated)
