# Phase 4 — Floating Widgets: REVIEW.md

Reviewer: code reviewer
Date: 2026-05-22
Scope: commits `0ac43ceb..HEAD` (Stage A–H + tests + GREEN.md)

---

## Verdict: SHIP-WITH-FIXES

The contract is honoured almost end-to-end: GlassDisk recipe is correct, AIChatOrb / VoiceChatLauncher / MiniPlayer / ReaderOverlay / GlobalMiniPlayer all match ARCH for the externally observable behaviour, all 4 reader screens were re-wired, TTSControls.tsx is deleted, both `_layout.tsx` branches mount the GlobalMiniPlayer, and `playerStore.repeatMode` lands cleanly with `'off' | 'one'` + initial `'off'` + `setRepeatMode`. The 4 documented GREEN.md deviations are each justified — most importantly, `VoiceState` really has no `'active'` member (`apps/mobile/lib/stores/chatStore.ts:29-35`), so the `connecting | listening | thinking | speaking` interpretation is correct.

The one finding that is properly a bug is the MiniPlayer pill backdrop (below). The rest are minor — a couple are explicit GREEN.md acknowledgements and not new regressions, but they will bite in QA so they're worth flagging.

---

## Critical findings

### 1. MiniPlayer pill renders against a transparent background after morph
**File**: `apps/mobile/components/player/MiniPlayer.tsx:298-313`
**Severity**: 🟡 Important (visual regression vs ARCH §4 / UI-SPEC; will be caught in screenshot review)

The outer `Animated.View` carries `overflow:'hidden'` and the interpolated `width / height / borderRadius`, but **no background of its own**. The `<GlassDisk size={52} style={{position:'absolute', top:0, left:0}}>` is hard-pinned to a 52×52 disk in the top-left corner of the morphing container. When `expandedValue` reaches 1 the container is 240–280pt wide × 66pt tall; the GlassDisk still only covers a 52pt corner.

The pill controls (lines 366–425) render inside that container at `top:0 left:0 right:0 bottom:0`. So the four PillIconButton hits (Prev / Play-Pause / Next / Stop, plus optional Repeat) sit on **bare transparent pixels** with no blur, no tint, no hairline border — directly over whatever happens to be under the reader (text, images, dark mode background).

GREEN.md §2 acknowledges the layering choice ("preserves the glass aesthetic at both sizes") but the resulting pill is the opposite of glass — it's invisible. ARCH §4 explicitly described the morph as "Both inside the morphing container" with cross-fade between orb-face and pill-face, where the *container itself* is the glass surface.

**Fix**: Drop the inner pinned-GlassDisk approach. Either (a) put the BlurView/border/tint *on the outer morphing Animated.View* (single glass container that scales), or (b) keep the corner-pinned 52pt disk for the orb face only and add a second GlassDisk that interpolates its own width with `expandedValue` to back the pill face. Option (a) is the simpler one and matches how the electron pill renders.

Unit tests do not catch this because `useAnimatedStyle` is stubbed to `{}`, BlurView is a host stub, and no assertion looks at the morphed container's background.

---

## Worth checking (lower confidence — call as you see fit)

### A. GlassDisk reads `useColorScheme()` directly instead of `useTheme()`
**File**: `apps/mobile/components/ui/GlassDisk.tsx:29`
**Severity**: 🟢 Polish
Convention drift vs ARCH §1 ("`useTheme()` consumed for scheme") and the rest of the Phase 2 primitives. Functionally identical — `useTheme()` is just a `useColorScheme()` wrapper — but it bypasses the centralized theme contract, so a future scheme override (e.g. forced reader theme) won't be honoured. One-line swap.

### B. `pathname?.startsWith('/reader')` matches `/readers`, `/reader-foo`, etc.
**File**: `apps/mobile/components/player/GlobalMiniPlayer.tsx:18`
**Severity**: 🟢 Polish
No such routes exist today so it doesn't bite, but a future `/readers` route would silently suppress the global player. `pathname === '/reader' || pathname?.startsWith('/reader/')` is the safe form.

---

## Confirmed correct

- **GlassDisk recipe** — outer shadow View + inner `overflow:'hidden'` clip, BlurView intensity 80, tint per scheme, hairline border with correct light/dark colours, conditional tint overlay only when `tintColor` provided. Two-View shadow workaround is intact (`GlassDisk.tsx:34-73`).
- **AIChatOrb** — 4 bar shared values + ring scale + ring opacity (6 total); useEffect cancels all 6 animations before re-arming; `idle || reduceMotion` rests bars at 1.0 (or 0.7 for reduceMotion); per-status `withDelay(i*stagger, withRepeat(withSequence(...), -1, true))` matches ARCH (300/150 speaking, 400/200 thinking, 350/150 connecting); ring pulses ONLY for `connecting && !reduceMotion`; static blue dot fallback for `connecting && reduceMotion`; ORB_TINTS at 24% alpha; bar heights `[8,14,20,12]`; per-status A11Y labels; `Haptics.selectionAsync()` gated on `!reduceMotion`.
- **VoiceChatLauncher** — single `breathScale`; breathing only on `!isActive && !reduceMotion`; cancelAnimation before re-arming; mic-outline ↔ mic-off-outline; `Haptics.selectionAsync()` on press (gated on `!reduceMotion`); accessibility labels/hints per state.
- **MiniPlayer state contract** — 5 useSharedValue (4 bars + expandedValue); `returns null` when idle OR `!send`; auto-collapse 4000ms timer set on (expanded && !isPlaying), cleared on every press via `bumpCollapse`; ActivityIndicator covers `loading | waitingForParagraphs | pageNavigating` (not just `loading`); Repeat button conditional on `repeatMode !== 'off'`; bottom offset branches between `'reader'` (with shellContext) and `'global'` (with tabBarHeight).
- **Morph math** — `[0, -(screenWidth/2 - 16 - pillWidth/2)]` correctly centers the pill on screen given the `right:16` anchor; verified algebraically.
- **ReaderOverlay state matrix** — All four states match ARCH §5: AIChatOrb iff isChatting; VoiceChatLauncher always; MiniPlayer iff `!isChatting && playingState !== 'idle'`. `voiceActive = connecting|listening|thinking|speaking` is the only safe derivation given `VoiceState` (confirmed at `chatStore.ts:29-35`).
- **ReaderShell integration** — `bookId?: string` and `onChatToggle?: () => void` added (`ReaderShell.tsx:72-73`); destructured into params; `<ReaderOverlay bookId={bookId} onChatToggle={onChatToggle} />` mounted after `<ReaderBottomBar>` (`ReaderShell.tsx:374`); all 4 readers pass `bookId={book.id}` (`[id].tsx:593`, `pdf/[id].tsx:470`, `mobi/[id].tsx:457`, `djvu/[id].tsx:384`); EPUB also passes `onChatToggle` wired through `requireAIChat` (`[id].tsx:594-596`).
- **TTSControls deletion** — file is gone; `grep -rn 'TTSControls' apps/mobile --include='*.ts*' | grep -v __tests__` returns zero.
- **GlobalMiniPlayer** — returns null on `/reader*` and on `idle`; mounted in both E2E and normal branches (`_layout.tsx:208, 221`); passes `variant='global'` + `tabBarHeight={49}` + correct testID.
- **playerStore additions** — `RepeatMode = 'off' | 'one'` exported (`playerStore.ts:41`); interface field at 61; initial state `'off'` at 89; `setRepeatMode` action at 99.
- **Reanimated rules-of-hooks** — bar styles are top-level `useAnimatedStyle` calls in both AIChatOrb (`AIChatOrb.tsx:169-180`) and MiniPlayer (`MiniPlayer.tsx:118-129`); no `useAnimatedStyle` inside `.map`. GREEN.md deviation #1 is honoured.
- **REPEAT event type** is part of `PlayerMachineEvent` union (`packages/shared/src/machines/playerMachine.ts:72`), so dispatching `{type:'REPEAT'}` from the Repeat button is type-safe even though the machine handler is Phase 5.

---

## Style / nits (≤5)

1. `MiniPlayer.tsx:251` — auto-collapse `useEffect` deps omit `setExpanded` (it's a stable setState setter, so this is fine, but the matching `bumpCollapse` callback at line 270 also captures `expanded`/`isPlaying` snapshots and could theoretically lag one render).
2. `AIChatOrb.tsx:154-163` — including the six shared values in the dep array is harmless (their identities are stable across renders) but conventional code adds an eslint-disable rather than listing them. Either is fine.
3. `MiniPlayer.tsx:194-202` — the morph spring fires on every `expanded` change but doesn't cancel a previous in-flight animation; in practice Reanimated handles this, but an explicit `cancelAnimation(expandedValue)` first would match the pattern AIChatOrb already uses.
4. `MiniPlayer.tsx:311` — the empty `<View style={StyleSheet.absoluteFill} />` inside the pinned GlassDisk is dead — GlassDisk doesn't fill via children, it fills via its internal BlurView. Remove or replace with the actual orb content if you fix finding #1.
5. `MiniPlayer.tsx:140` — `tabBarHeight ?? 49` shadows the `TAB_BAR_HEIGHT = 49` already declared in GlobalMiniPlayer. Consider exporting a shared constant from one place so future tab-bar changes touch one literal, not two.

---

## Out of scope (Phase 5+ notes)

- **REPEAT semantics**: the button dispatches `{type:'REPEAT'}` but the machine guard/transition wiring is a Phase 5 deliverable per GREEN.md. Until then, the button only appears when `repeatMode !== 'off'` and tapping it has no observable effect; this matches the contract.
- **`bookId` parameter on MiniPlayer is unused** (`_bookId`). Forward-compatibility hook; not a bug.
- **Auto-collapse + jest act-warning** (GREEN.md open issue): cosmetic, tests still pass. Inject the timer or use `Animated.delay` when it gets noisier.
- **Drag-to-reposition** and **dynamic `useBottomTabBarHeight()`** are explicitly deferred (ARCH OQ5/OQ7).
- **Bottom-offset jump when collapsing** (`MiniPlayer.tsx:141-146`): when `expanded` flips false, `bottomOffset` instantly jumps from `insets.bottom+16` to `insets.bottom+16+44` (if bottom bar visible). This isn't animated; the pill snap-translates upward as it shrinks. Worth a screenshot pass once the backdrop fix lands; if it looks jarring, animate the `bottom` separately or move the bottom-bar offset onto the morph interpolation. Not a Phase 4 blocker.
