# Phase 4 — Floating Widgets: GREEN.md

Date: 2026-05-22
Author: coder agent
Mode: TDD green phase

---

## Per-stage commits

| Stage | Commit  | Header |
|-------|---------|--------|
| A     | 8e628910 | feat(mobile/ui): GlassDisk primitive for glass-morphism circles |
| B     | 71adf72c | feat(mobile/chat): AIChatOrb with Reanimated 3 waveform |
| C     | 21cbbcfb | feat(mobile/chat): VoiceChatLauncher with breathing animation |
| D     | 93a1e46c | feat(mobile/player): MiniPlayer with orb-to-pill morph |
| E     | 2ba1bf02 | feat(mobile/reader): ReaderOverlay orchestrates floating widgets |
| F     | f9d97ec4 | feat(mobile): ReaderShell mounts ReaderOverlay |
| G     | 5db91bd9 | refactor(mobile): delete TTSControls (replaced by MiniPlayer) |
| H     | 0ee43f8c | feat(mobile/player): GlobalMiniPlayer persists across navigation |

---

## Files created (6)

- `apps/mobile/components/ui/GlassDisk.tsx`
- `apps/mobile/components/chat/AIChatOrb.tsx`
- `apps/mobile/components/chat/VoiceChatLauncher.tsx`
- `apps/mobile/components/player/MiniPlayer.tsx`
- `apps/mobile/components/player/GlobalMiniPlayer.tsx`
- `apps/mobile/components/reader/ReaderOverlay.tsx`

## Files modified

- `apps/mobile/components/ui/index.ts` — exports GlassDisk
- `apps/mobile/lib/stores/playerStore.ts` — adds `repeatMode` + `setRepeatMode`
- `apps/mobile/components/reader/ReaderShell.tsx` — adds `bookId` + `onChatToggle` props; renders `<ReaderOverlay>` after `<ReaderBottomBar>`
- `apps/mobile/app/reader/[id].tsx` — drops TTSControls; passes `bookId` + `onChatToggle` to ReaderShell
- `apps/mobile/app/reader/pdf/[id].tsx` — drops TTSControls; passes `bookId` to ReaderShell; updates stale comment
- `apps/mobile/app/reader/mobi/[id].tsx` — drops TTSControls; passes `bookId` to ReaderShell
- `apps/mobile/app/reader/djvu/[id].tsx` — drops TTSControls; passes `bookId` to ReaderShell
- `apps/mobile/app/_layout.tsx` — mounts `<GlobalMiniPlayer>` after `<Slot>` in both render branches
- `apps/mobile/__tests__/components/reader/ReaderShell.test.tsx` — adds virtual stub for the new ReaderOverlay dependency so the existing 8-test suite stays isolated from expo-blur / Reanimated

## Files deleted

- `apps/mobile/components/TTSControls.tsx`

---

## Final test counts

| Suite           | Pass    | Total  | Notes |
|-----------------|---------|--------|-------|
| Shared          | 496     | 496    | Untouched |
| Mobile          | 670     | 670 of running suites (3 baseline module-load failures persist) | 618 baseline + 44 new Phase 4 + 8 incidental (ReaderShell + others picked up extra tests from prior stages) |
| Electron `typecheck:web` | — | — | exits clean |
| Mobile `tsc --noEmit`  | — | — | exits clean |

44 new Phase 4 test cases distributed:

- GlassDisk: 5
- AIChatOrb: 7 (15 with `.each` expansion — 4 statuses × 2 it.each + 7 base = 15 actual)
- VoiceChatLauncher: 6
- MiniPlayer: 12
- ReaderOverlay: 8
- GlobalMiniPlayer: 6

The 3 baseline failures (book-import x2, vector) are unchanged from the
pre-Phase 4 state — they fail at module import on real native modules
(quick-sqlite / expo-file-system) and are documented baseline.

---

## Deviations from ARCH (with rationale)

1. **MiniPlayer rules-of-hooks compliance** — ARCH §4 suggests "4 bars
   useSharedValue + useAnimatedStyle inside `.map`". Inlining
   `useAnimatedStyle` in a `.map` callback would trigger react-hooks/exhaustive
   warnings even though the iteration count is stable. Resolved by hoisting
   `bar0Style…bar3Style` to top-level useAnimatedStyle calls and mapping the
   pre-computed array. No observable behavior change.

2. **Background GlassDisk on MiniPlayer** — the orb-to-pill morph wraps the
   entire animated container in a `<GlassDisk size={52}>` positioned at
   `top:0 left:0` so the blur stays anchored to the orb corner regardless of
   pill width. The pill's controls render outside the disk's clip via a
   sibling Animated.View. This keeps the morph cheap (one Animated.View
   width/height interpolation) while preserving the glass aesthetic at both
   sizes. ARCH described the morph but left the disk-layering choice open.

3. **EPUB reader `onChatToggle`** — ARCH §9 routes the EPUB chat toggle
   through `requireAIChat(() => router.push(\`/chat/${book.id}\`))`. The
   existing `onChatPress` prop already had that wiring; I forwarded the
   same call site to `onChatToggle` so the orb tap matches the bottom-bar
   chat button. Both props point at the same handler — no divergence.

4. **`voiceActive` derivation** — ARCH §5 says `voiceState === 'active' ||
   'listening' || 'speaking'`, but the mobile `VoiceState` type defines
   `'connecting' | 'listening' | 'thinking' | 'speaking' | 'error' | 'idle'`
   (no `'active'` member). I treated `connecting | listening | thinking |
   speaking` as voice-active, matching the electron orb's "while connected
   to the agent in any way" semantic. Tests don't pin the exact state set
   — they only verify VoiceChatLauncher is ALWAYS mounted — so this is a
   safe interpretation.

---

## Open issues for reviewer / Phase 5

- **MiniPlayer auto-collapse timer + jest warning**: the setTimeout in the
  4000ms auto-collapse fires after some MiniPlayer tests finish (when
  expanded but playingState !== 'playing'). Jest emits a "state update
  outside of `act()`" warning + a worker-leak note. All assertions still
  pass; this is cosmetic. A real fix would inject the timer via a hook
  parameter (or call `Animated.delay`) so tests can drive it
  deterministically. Flagged to the tester for Phase 5 if the noise
  becomes blocking.

- **`useAnimatedStyle` stub in tests**: returns `{}` (passthrough), so
  the orb-fade and pill-fade cross-fade isn't exercised in unit tests.
  E2E coverage for the actual morph is Phase 4 §10 stage 8 (screenshots),
  not unit tests.

- **`bookId` parameter on MiniPlayer**: currently unused (`_bookId`).
  Wiring for "the reader-mounted instance restarts playback against
  THIS book" is the responsibility of `usePlayerMachine`, not MiniPlayer.
  Left the prop in the public API for forward compatibility.

- **Repeat button is visual-only**: ARCH §7 says the loop wiring is
  Phase 5. The button dispatches `{type: 'REPEAT'}` but the player
  machine doesn't yet act on it — it just appears/disappears based on
  `repeatMode`. The Repeat icon also doesn't render in `repeatMode='off'`
  (per the test contract).

- **GlobalMiniPlayer + tab bar offset**: hardcoded 49pt per ARCH §1
  OQ5 decision. Once `useBottomTabBarHeight()` is safe to call outside
  reader (Phase 6 work), swap this constant out.

- **Drag-to-reposition**: deferred per ARCH §1 OQ7.

---

## Done-when checklist

- [x] GlassDisk, AIChatOrb, VoiceChatLauncher, MiniPlayer, ReaderOverlay, GlobalMiniPlayer all exist
- [x] playerStore has `repeatMode` + `setRepeatMode`
- [x] TTSControls.tsx deleted; grep returns zero refs (only stale code comments updated)
- [x] All 4 reader screens cleaned; bookId passed to ReaderShell
- [x] ReaderShell mounts ReaderOverlay
- [x] _layout.tsx mounts GlobalMiniPlayer in both render branches
- [x] 44 new tests pass; mobile total 670 (≥662 target)
- [x] Mobile + electron typecheck clean
- [x] 8 commits with Conventional Commits headers
