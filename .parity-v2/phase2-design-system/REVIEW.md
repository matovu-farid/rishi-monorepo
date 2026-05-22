# Phase 2 — Design System Foundation: REVIEW.md

Reviewer: team-reviewer
Date: 2026-05-22
Scope: commits `1c5587e4..fdad0d00` (7 commits) — tokens, theme hook, 10 primitives, BookRow/library refactor, expo-blur install.

---

## Verdict: **SHIP-WITH-FIXES**

The token + primitive foundation is solid. Tests pass, types check, electron is untouched, deviations are documented and justified. One install-time bug (wrong expo-blur version) will break Phase 3 the moment `<BlurView>` is imported, and one accessibility-spec deviation in `PressableScale`/`IconButton` is worth tightening. Neither blocks merge today, but #1 must be fixed before Phase 3 touches the Toolbar.

---

## Critical findings (must fix)

### F1 — `expo-blur` is on the SDK 53 line; Expo SDK 54 expects `~15.0.x`  ·  Severity: 🔴 Block ship (Phase 3)
- **File**: `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/package.json:28`
- **Evidence**:
  - Mobile is on Expo SDK 54 (`expo: ~54.0.33`).
  - `apps/mobile/node_modules/expo/bundledNativeModules.json` resolves `expo-blur` to `~15.0.8` for SDK 54.
  - This branch pinned `"expo-blur": "~14.1.5"` (SDK 53's version). All sibling Expo modules (`expo-crypto 15.x`, `expo-constants 18.x`, `expo-haptics 15.x`) are on the SDK 54 line — `expo-blur` is the outlier.
  - `expo-blur@14.x` peerDeps are `expo: '*'`, so npm/lockfile didn't warn; this will fail at native build / runtime when `<BlurView>` is first imported in Phase 3.
- **Why it matters**: Phase 3's Toolbar enhancement is the next consumer. Importing `<BlurView>` against an ABI-mismatched native module will crash on first reader-screen mount or fail Xcode/Gradle linking. Today's diff doesn't import it yet, so tests pass — but the Toolbar's `// TODO Phase 3` comment in `apps/mobile/components/ui/Toolbar.tsx:24` will trigger this within the next sprint.
- **Fix**: Run `npx expo install expo-blur` (from `apps/mobile`) to let Expo pick the SDK-aligned version, then regenerate the lockfile. The `app.json` plugins entry stays.

### F2 — `PressableScale` forwards `disabled` to the underlying `Pressable`, contradicting the IconButton spec  ·  Severity: 🟡 Important
- **File**: `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/PressableScale.tsx:84`
- **Evidence**: UI-SPEC §7c says, verbatim, "Disabled: ... do not pass `disabled` to Pressable so VoiceOver still announces, then provide `accessibilityState={{ disabled: true }}`." The implementation passes `disabled={disabled}` to the host `Pressable` (line 84) AND sets `accessibilityState={{ disabled }}` (line 88). RN's `Pressable` with `disabled=true` hides the element from the VoiceOver focus rotor in some assistive technologies, making the button silently un-findable instead of being announced as "dimmed."
- **Why it matters**: `IconButton` and `ListRow` both lean on `PressableScale` for their disabled state. A disabled appearance sheet toggle, sign-in CTA, or destructive list row would vanish from VoiceOver entirely instead of being announced and skipped over with the standard "disabled" cue. Phase 2's accessibility baseline (UI-SPEC §10.2) is a non-negotiable.
- **Fix**: Drop `disabled={disabled}` from the `Pressable` props. Keep the early-returns in `handlePress*` and `accessibilityState={{ disabled }}`. The `disabled` opacity styling (line 91) already provides the visual cue.

### F3 — `Hairline` with `inset > 0` overflows its parent  ·  Severity: 🟡 Important (Phase 3 risk; default `inset=0` is fine today)
- **File**: `/Users/faridmatovu/projects/rishi-monorepo/apps/mobile/components/ui/Hairline.tsx:22-34`
- **Evidence**: For horizontal orientation the style is `{ height: hairlineWidth, width: '100%', marginLeft: inset }`. `width: '100%'` is 100% of the parent — adding `marginLeft: inset` pushes the right edge `inset` pt outside the parent. UI-SPEC §7d documents the intent as "`width: '100%'` minus `inset` on left." Symmetric bug on the vertical branch.
- **Why it matters**: ListRow (UI-SPEC §7i) is documented to render a hairline with `inset={56}` for icon rows starting Phase 3. With this bug, every ListRow's divider will bleed 56pt past the right gutter, which on iPhone is visible as a hairline running into the safe-area / shadow region. The default `inset=0` is fine, so Phase 2's BookRow refactor doesn't exhibit the bug yet.
- **Fix**: Switch to flex sizing: drop `width: '100%'` and add `alignSelf: 'stretch'` + the existing `marginLeft: inset`. RN's stretch alignment shrinks to remaining axis-cross space. Verify by snapshot-testing ListRow once Phase 3 starts.

---

## Confirmed correct

- **Color tokens** (`apps/mobile/lib/theme/colors.ts`) — all UI-SPEC §1 hex/rgba values match (verified: light `background.secondary='#F2F2F7'`, dark `background.secondary='#1C1C1E'`, light `accent.primary='#0a7ea4'`, dark `accent.primary='#3AB4D6'`, separator pair, fill ladder, reader paper/ink, all 5 highlight tints). Light/dark key parity enforced by `tokens.test.ts`.
- **Spacing scale** (`tokens.ts:3-16`) — 4pt grid, monotonic 0→2→4→8→12→16→20→24→32→40→56→80, all 12 t-shirt keys present.
- **Typography sizes** (`typography.ts:29-40`) — iOS HIG-aligned: display-large 34, body 17, caption-small 11, reader-body 17/25.5 (1.5× relaxed lineHeight). Weight tokens map to '400'/'500'/'600'/'700' strings as the spec mandates.
- **Motion** — `motion.duration.fast=200` per UI-SPEC §5 (the deviation #1 documented in GREEN.md is justified — UI-SPEC trumped the prompt's 150). Spring presets are raw Reanimated coefficients per architect's documented choice.
- **Shadow tokens** match UI-SPEC §6.1 (low opacity 0.06, height 1, radius 2, etc.).
- **`useTheme`** — `useColorScheme` resolves palette; `AccessibilityInfo` subscription cleans up via `cancelled` flag + `sub.remove()` in cleanup; result memoized on `[scheme, reduceMotion]` and tests pin reference stability.
- **`IconButton` hitSlop = 11 per side** (`IconButton.tsx:24`) — 22 + 22 = 44pt minimum touch target, satisfies UI-SPEC §10.3.
- **`PressableScale`** correctly uses `useSharedValue`/`useAnimatedStyle`/`withSpring`/`withTiming` with reduce-motion bypass via opacity (`PressableScale.tsx:46-72`).
- **`Sheet`** — backdrop has `pressBehavior="close"` (line 78); `onChange(-1) → onClose` wired (line 67); plain `BottomSheet` matches the root layout (no `BottomSheetModalProvider`) per documented deviation #8.
- **`BookCover`** — sizes 48/96/144 (`BookCover.tsx:22-26`); hash-based fallback deterministic per title (verified by `BookCover.test.tsx:111-140`); first-letter rendering; `hairlineWidth` border + `borderRadius`.
- **`Hairline`** uses `StyleSheet.hairlineWidth`, not literal 1pt (line 24,30).
- **`SegmentedControl`** — pill is a Reanimated `Animated.View` driven by `useSharedValue` + `useAnimatedStyle` with percentage `translateX` (works on RN 0.81); no React state-driven layout.
- **ORB colors shared** — `packages/shared/src/tokens/orb-colors.ts` matches `apps/rishi-electron/src/renderer/src/components/chat/AIChatOrb.tsx:30-41` verbatim (spaced rgba). Package exports configured (`packages/shared/package.json:61`).
- **expo-blur in app.json plugins** (`apps/mobile/app.json:135`) — present, NOT yet enabled in `Toolbar.tsx` (Phase 3 work, confirmed by the `// TODO Phase 3` comment).
- **BookRow refactor preserves existing testIDs** — `library-book-row-${id}` (new, what e2e helpers already expected per `e2e/helpers/seed-book.ts:43`), `book-row-title`, `book-delete-button` all intact; new `book-row-cover-${id}` adds the cover testID.
- **Deferred primitive tests** (Toolbar, SearchBar, EmptyState) are explicitly listed as Phase-3 deferrals in `TESTS.md:43-45` — not accidentally skipped.
- **No new `any` types in `apps/mobile/components/ui/*.tsx` or `apps/mobile/lib/theme/*.ts`**.
- **No new `eslint-disable` directives**.
- **Electron untouched** — diff is contained to mobile + `packages/shared/src/tokens`.

---

## Style / nits (non-blocking)

1. `Sheet.tsx:57-63` — the `useEffect(expand/close)` is redundant with `index={isOpen ? 0 : -1}` (line 90). gorhom syncs index↔ref in both directions; pick one. Belt-and-suspenders is harmless but dead code.
2. `SearchBar.tsx:60` — `onClear ? onClear() : onChange('')` uses the conditional expression as a statement; prettier/eslint normally rewrites to an `if` for readability.
3. `BookCover.tsx:79-94` — `overflow: 'hidden'` on the same View as the shadow style clips the shadow on iOS. Move shadow to an outer wrapping View if Phase 3 wants visible lift on covers.
4. `EmptyState.tsx:27-33` — `typeof icon === 'string'` check then casts back to `keyof typeof Ionicons.glyphMap`. The cast is safe but the original prop type `keyof typeof Ionicons.glyphMap | ReactNode` collapses to `string | ReactNode` after type erasure; consider a discriminated `{ kind: 'name', name } | { kind: 'node', node }` if this grows.
5. `hooks/use-theme-color.ts` — not migrated to a `useTheme()` shim (UI-SPEC §11 listed this as Phase 2 work). Old hook still functions on the legacy `Colors` constant; doesn't break anything, but the migration is now pending Phase 3.

---

## Out of scope for Phase 2 (notes for Phase 3+)

- `<BlurView>` wiring inside `Toolbar.tsx` (line 24 marked `// TODO Phase 3`) — depends on F1 above being fixed first.
- `BottomSheetModalProvider` decision — Sheet uses plain `BottomSheet` today (documented deviation #8). Phase 3 can switch to `BottomSheetModal` once the root layout mounts the provider.
- ListRow's per-row hairline (UI-SPEC §7i bottom) — currently the parent list is expected to render `<Hairline inset={56} />` between rows. Phase 3 list redesign will exercise this; F3 must land before then.
- `useThemeColor` compat shim (UI-SPEC §11) — punted by the architect; Phase 3 reader migration will likely consume it.
- `ThemedText` deprecation — UI-SPEC §11 keeps it in Phase 2; Phase 3 should replace call sites with inline `useTheme().typography.scale.*`.

---

End of REVIEW.md.
