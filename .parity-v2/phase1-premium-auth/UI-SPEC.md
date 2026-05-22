# Phase 1 — Mobile PremiumFeatureSheet UI Spec

Date: 2026-05-22
Status: Approved for implementation
Owner: designer (gsd-ui-researcher)
Audience: coder agent (team-coder)
Reference: [docs/superpowers/specs/2026-05-22-mobile-parity-v2-design.md](../../docs/superpowers/specs/2026-05-22-mobile-parity-v2-design.md)
Electron reference: [apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx](../../apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx), [features.ts](../../apps/rishi-electron/src/renderer/src/components/auth/features.ts)

---

## 0. Intent (read this first)

When a signed-out user taps a premium control (TTS play, mic for voice chat, AI chat composer, sync action), instead of bouncing them to the full `(auth)/sign-in` screen, mobile presents a bottom sheet that:

- Names the feature in one short sentence
- Offers a single primary CTA to sign in
- Lets them dismiss with a swipe or a quiet text button

The bar is **Apple Books' own sign-in prompts**: quiet, premium, no jargon, no marketing bullets, no gradients, no badges, no "AI-powered" hype. The sheet is a tool for the user, not a conversion funnel.

This sheet is **distinct from the existing `app/(auth)/sign-in.tsx` screen**: that screen is the authoritative sign-in destination after onboarding or a tab tap on a sign-in CTA. The sheet is an inline gate that opens the in-app OAuth browser directly when the user accepts. There is no email/password path in the sheet — that lives on the full screen.

The component is named **`PremiumFeatureSheet`** and ships at `apps/mobile/components/auth/PremiumFeatureSheet.tsx`. It is mounted once at the root layout and controlled by `useAuthStore` slice extensions (`premiumGateOpen`, `premiumGateFeature`, `openPremiumGate(feature)`, `closePremiumGate()`).

---

## 1. Anatomy

The sheet is a single snap-point `@gorhom/bottom-sheet` (the library is already in `package.json` — see `components/AppearanceSheet.tsx` for the existing pattern). Snap point: **content-sized**, target ~360 pt tall in default state on a 6.1" device. `enablePanDownToClose`, no detents above content height.

Top-to-bottom regions (with vertical spacing in 4-pt grid units):

| Region | Spec |
|---|---|
| **Backdrop** | Black at 32% opacity. Tap to dismiss. Fades in 200ms ease-out. |
| **Grabber (drag indicator)** | 36 × 5 pt pill, radius 2.5 pt, color `separator.opaque` (light: `rgba(60,60,67,0.29)`, dark: `rgba(84,84,88,0.65)`). 8 pt top inset from sheet top, centered. |
| **Top spacer** | 28 pt below grabber → 40 pt total from sheet top to icon. |
| **Icon disc** | 56 × 56 pt circle, `fill.secondary` background (light `rgba(120,120,128,0.16)`, dark `rgba(120,120,128,0.32)`). Icon glyph 26 pt, `text.primary`. Centered horizontally. |
| **Icon → title spacer** | 20 pt. |
| **Title** | `text.primary`. SF Pro Display Semibold 22 pt / 28 pt line height. Centered. Max 2 lines, `numberOfLines={2}`. |
| **Title → body spacer** | 8 pt. |
| **Body** | `text.secondary`. SF Pro Text Regular 15 pt / 22 pt. Centered. `textAlign="center"`. 32 pt horizontal padding. Max 3 lines, `numberOfLines={3}`. |
| **Body → CTA spacer** | 28 pt. |
| **Primary CTA** | Full-width filled button. Height 50 pt. Radius 14 pt. Background `tint.primary` (light `#0a7ea4` to match existing app palette, dark `#5AC8FA`). Label SF Pro Text Semibold 17 pt, color `text.onTint` (`#FFFFFF`). Horizontal padding 20 pt. |
| **CTA → secondary spacer** | 12 pt. |
| **Secondary CTA** | Borderless text button, full-width touch target, height 44 pt. Label "Not now", SF Pro Text Regular 15 pt, color `text.secondary`. |
| **Bottom inset** | 20 pt + `useSafeAreaInsets().bottom`. |

### Icon library

Use **Ionicons** from `@expo/vector-icons` (already imported across mobile). Names are stable and ship with the bundle. No Lucide on mobile — Lucide is the electron-only dep.

### Primary CTA copy — provider selection

The mobile `authStore` and `lib/auth.ts` expose three providers: `'google' | 'apple' | 'password'`. The sheet uses **only one** OAuth provider and routes to that one when tapped — no provider picker inside the sheet (that's noise).

Decision per platform:

| Platform | Primary CTA label | Provider passed to `signIn()` |
|---|---|---|
| iOS (Apple App Store + dev) | `Continue with Apple` | `'apple'` |
| Android | `Continue with Google` | `'google'` |

Detect via `Platform.OS === 'ios'`. The decision is hard-coded at component level — no toggle, no fallback list. Users who need email/password or a different provider tap the secondary affordance or open Settings → Sign in, which routes to the full `(auth)/sign-in` screen. (Note: as of 2026-05-22 `lib/auth.ts` does not yet implement `'apple'` end-to-end — coder must wire `signIn('apple')` through the same Better-Auth `startAuthSession` path the worker already supports. If that wiring slips, fall back to `'google'` on iOS and the label becomes `Continue with Google` everywhere; flag in code review.)

### Secondary CTA

Label: **`Not now`**. Exactly that — not "Cancel", not "Maybe later", not "Dismiss". Quiet, low contrast. Tapping is identical to swipe-to-close: calls `closePremiumGate()` and emits `Haptics.selectionAsync()`.

### What is NOT in the sheet

- No bullets / feature list (electron has them; mobile strips them — the design philosophy demands restraint)
- No badge ("Premium", "AI", "Pro") — never
- No "Sign in to Rishi" branding line — the title carries the intent
- No close (×) icon — the grabber + backdrop + Not now button are sufficient
- No email/password field
- No "Use a different account" link
- No upsell text ("Free with account", "No credit card", etc.)

---

## 2. Per-feature copy table

The `PremiumFeature` enum on mobile aligns with the shared package being extracted in this phase:

```
type PremiumFeature = 'tts' | 'voice-chat' | 'ai-chat' | 'sync' | 'ai-generic'
```

Note: this **renames** electron's `'chat' | 'voice-input'` to `'ai-chat' | 'voice-chat'` for clarity. Electron will be rewired to consume the shared names in this same phase (see master design "Electron rewire"). Electron's `'chat'` → `'ai-chat'`, `'voice-input'` → `'voice-chat'`, plus a new `'sync'` member.

| Feature | Title (4-6 words) | Body (≤18 words) | Icon name (Ionicons) |
|---|---|---|---|
| `tts` | Sign in to listen | Sign in to hear your books read aloud in expressive voices. | `headset-outline` |
| `voice-chat` | Sign in to talk | Sign in to ask questions out loud and hear answers back. | `mic-outline` |
| `ai-chat` | Sign in to ask | Sign in to chat about what you're reading and get cited answers. | `chatbubble-ellipses-outline` |
| `sync` | Sign in to sync | Sign in to keep your library, highlights, and progress across devices. | `cloud-outline` |
| `ai-generic` | Sign in to continue | Sign in to use Rishi's reading tools. | `sparkles-outline` |

Copy rules followed:
- No "AI", "AI-powered", "intelligent" except in `ai-chat` body where "cited answers" implies it
- No "your books" twice in one row; each entry sounds distinct
- Each title starts with "Sign in to …" so the verb tells the user exactly what will happen on tap
- Each body is one sentence, ends with a period, never has em-dashes or semicolons

These strings live in **`packages/shared/src/auth-gating/featureCopy.ts`** (the shared package being created in this phase) and are imported by both mobile and electron. Strings MUST be sourced from that file — no local duplicates.

---

## 3. States

### 3a. Default (idle)

As described in Anatomy. Primary CTA enabled, label = `Continue with Apple` / `Continue with Google`, no spinner, no error row.

### 3b. Signing in

Triggered immediately when the primary CTA is pressed; `useAuthStore.isAuthenticating === true` is the source of truth (already exists). The sheet does NOT auto-close while `isAuthenticating` — it stays mounted so a cancelled browser session brings the user back to a clear state.

- CTA label is replaced by a centered `<ActivityIndicator size="small" color={text.onTint} />`
- CTA `disabled={true}`, `accessibilityState={{ disabled: true, busy: true }}`
- Secondary CTA ("Not now") stays enabled
- Grabber stays visible; pan-to-close stays enabled (user can always escape)
- No timeout in the sheet itself — the in-app browser owns the lifecycle

### 3c. Error

Triggered when `signIn(provider)` rejects with anything other than a cancel/dismiss (the existing `(auth)/sign-in.tsx` already filters those via `/cancel|dismiss/i.test(msg)`; reuse that predicate).

- Inline error row appears between the CTA and the secondary button
- Spacing: 12 pt above (replacing the 12 pt secondary spacer), then the error text, then 12 pt below before "Not now"
- Error glyph: `Ionicons name="alert-circle" size={16}` color `state.error` (light `#D70015`, dark `#FF453A`), 6 pt right margin
- Error text: SF Pro Text Regular 13 pt / 18 pt, color `state.error`, single line, `numberOfLines={1}`, `ellipsizeMode="tail"`
- Exact copy: **`Couldn't sign in. Try again.`** (curly apostrophe `'`, no period after "again" omitted — period stays)
- Sheet performs a single horizontal shake: 6 pt right → -6 pt left → 4 pt right → -4 pt left → 0, 300ms total, ease-in-out, via Reanimated `withSequence(withTiming(...))`. Spec the worklet on the sheet container, not the error row.
- On next CTA press, error clears immediately (set local state `error = null` at the top of the press handler)

`isAuthenticating` returns to `false` when the error occurs (handled by existing `signIn()` finally block).

---

## 4. ASCII mockup — Default state, `tts` feature, iOS, light mode

```
   ╭──────────────────────────────────────────────╮
   │                                              │   ← backdrop (32% black)
   │                                              │
   │                                              │
   │                                              │
   │  ┌────────────────────────────────────────┐  │   ← sheet, radius 16 pt top
   │  │                ▬▬▬▬                    │  │   ← grabber, 36x5
   │  │                                        │  │
   │  │                                        │  │   ← 28 pt
   │  │                ╭────╮                  │  │
   │  │                │ ⌬  │                  │  │   ← icon disc 56x56,
   │  │                ╰────╯                  │  │      headset glyph 26pt
   │  │                                        │  │
   │  │                                        │  │   ← 20 pt
   │  │           Sign in to listen            │  │   ← title 22/28 semibold
   │  │                                        │  │
   │  │       Sign in to hear your books       │  │   ← body 15/22 regular
   │  │       read aloud in expressive         │  │      text.secondary
   │  │                voices.                 │  │
   │  │                                        │  │
   │  │                                        │  │   ← 28 pt
   │  │  ┌──────────────────────────────────┐  │  │
   │  │  │      Continue with Apple         │  │  │   ← CTA 50pt, tint bg
   │  │  └──────────────────────────────────┘  │  │
   │  │                                        │  │   ← 12 pt
   │  │              Not now                   │  │   ← secondary, 15pt
   │  │                                        │  │
   │  │                                        │  │   ← 20 pt + safe area
   │  └────────────────────────────────────────┘  │
   ╰──────────────────────────────────────────────╯
```

Proportions: total sheet height ~360 pt on iPhone 15 Pro (393 × 852 pt). Sheet occupies bottom ~42% of viewport. Backdrop fills the rest.

### Dark mode delta

- Sheet background: `background.elevated` = `#1C1C1E`
- Hairline above sheet: none — rely on backdrop contrast and rounded corners
- Icon disc: `rgba(120,120,128,0.32)` fill, glyph `#FFFFFF`
- Title: `#FFFFFF`
- Body: `rgba(235,235,245,0.6)` (iOS `secondaryLabel` dark)
- CTA bg: `#5AC8FA` (iOS `systemBlue` dark; or keep `#0a7ea4` if app already standardizes on it — pick one and apply globally in Phase 2 tokens)
- CTA text: `#000000` if bg is `#5AC8FA` (contrast); `#FFFFFF` if bg is `#0a7ea4`
- Grabber: `rgba(84,84,88,0.65)`
- Error: `#FF453A`

---

## 5. Motion

All animations driven by Reanimated 3 (already in package.json) and `@gorhom/bottom-sheet`'s built-in spring config.

| Event | Spec |
|---|---|
| Sheet enter | `@gorhom/bottom-sheet` `animationConfigs` set to spring: `damping: 0.85`, `stiffness: 250`, `mass: 1`. Use `useBottomSheetSpringConfigs` helper from the lib. |
| Backdrop fade in | 200ms, `Easing.out(Easing.quad)`. Implement via custom `backdropComponent` returning an `Animated.View` reading `animatedIndex` from `useBottomSheetInternal`. |
| Drag-to-close threshold | Close if user drags sheet down by ≥ 30% of sheet height. The library exposes this via the `index` snap-point system; set `enablePanDownToClose` and rely on default 30% — confirm by inspecting current `AppearanceSheet.tsx` behaviour and matching it. |
| Velocity-based dismiss | Close if release velocity > 500 px/s downward, regardless of drag distance. `@gorhom/bottom-sheet` enables this by default with `enablePanDownToClose`. Do not override. |
| Spring-back | If neither threshold is met, sheet springs back to fully open with the same `damping: 0.85, stiffness: 250` config. |
| Sheet exit (dismiss) | Mirror the spring config. Backdrop fades out in 200ms in parallel. |
| Error shake | Sheet container x-translation: `0 → 6 → -6 → 4 → -4 → 0`, each step 60ms, ease-in-out. Single play per error. Drive via `useSharedValue` + `withSequence`. |

No gradients. No scale-in/scale-out. No glow. The sheet enters from below, fades a backdrop, lands. That's it.

---

## 6. Haptics

All via `expo-haptics` (already installed). Fire on the JS thread immediately before the corresponding state transition — do not wrap in worklets.

| Event | API call | Trigger point |
|---|---|---|
| Sheet open | `Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Soft)` | In `useEffect(() => {...}, [premiumGateOpen])` when transitioning `false → true` |
| Primary CTA press | `Haptics.selectionAsync()` | At the very top of the press handler, before `signIn()` is called |
| Secondary CTA press | `Haptics.selectionAsync()` | At top of "Not now" handler |
| Sign-in success | `Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)` | In the `signIn()` `.then` after `setSession()` succeeds, before the sheet animates closed |
| Sign-in error | `Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)` | In the `signIn()` `.catch` after the cancel-filter rejects the message, simultaneous with the shake animation start |
| Pan-down dismiss | None (the OS dismiss gesture already provides tactile feel via scroll physics; adding a haptic would feel chatty) |

Haptics are skipped automatically on Android by the OS where the device lacks the matching engine — no extra branching needed.

---

## 7. Accessibility

### Sheet container

- `accessibilityViewIsModal={true}` on the sheet content View — VoiceOver ignores siblings while the sheet is open
- `accessibilityRole="dialog"` (RN maps this to `UIAccessibilityTraitNone` on iOS but conveys intent for testers)
- On mount, send a `findNodeHandle` + `AccessibilityInfo.setAccessibilityFocus()` to the title `Text` after the open-spring settles (≈ 350ms post-mount). The announcement that VoiceOver speaks is `"<title>. <body>"` concatenated by the focus, exactly matching the visible copy.

### Primary CTA

- `accessibilityRole="button"`
- `accessibilityLabel={'Continue with Apple'}` (or Google) — provider-specific
- `accessibilityHint={'Opens a secure browser to sign in.'}`
- `accessibilityState={{ disabled: isAuthenticating, busy: isAuthenticating }}`

### Secondary CTA

- `accessibilityRole="button"`
- `accessibilityLabel={'Not now'}`
- `accessibilityHint={'Closes this prompt without signing in.'}`

### Icon disc

- `accessibilityElementsHidden={true}` (it's decorative; the title carries meaning)
- `importantForAccessibility="no"` (Android equivalent)

### Dynamic Type

- All text uses RN's default `allowFontScaling={true}`
- Title and body have **no fixed height** — they grow naturally and the sheet content size grows with them (snap-point `'CONTENT_HEIGHT'`)
- At the largest accessibility size (`UIContentSizeCategoryAccessibilityExtraExtraExtraLarge`), the sheet may grow to ~80% of viewport; verify the secondary CTA still fits above safe area inset in the simulator at that setting before merging

### prefers-reduced-motion

- Read via `AccessibilityInfo.isReduceMotionEnabled()` once on mount; subscribe to `reduceMotionChanged`
- When reduce-motion is on:
  - Sheet enter/exit: linear `withTiming` over 250ms instead of spring
  - Backdrop fade: keep (it's already 200ms linear-ish)
  - Error shake: replaced by a single 80ms opacity flash of the error row (`0 → 1`)
- Implement as a single `motionPreset` shared value passed into the sheet's `animationConfigs`

### Error announcement

- The error `Text` has `accessibilityLiveRegion="polite"` (Android) and on iOS the parent View calls `AccessibilityInfo.announceForAccessibility("Couldn't sign in. Try again.")` once when the error is set
- The CTA's `accessibilityLabel` does NOT change to include the error — keep CTA label stable

---

## 8. Light/dark mode tokens

Use semantic tokens that the Phase 2 design system will codify. For Phase 1, hard-code the values listed below inside `PremiumFeatureSheet.tsx` with `useColorScheme()` branching — Phase 2 will refactor them into `lib/theme/tokens.ts`.

| Token | Light | Dark | iOS UIKit equivalent |
|---|---|---|---|
| `background.elevated` | `#FFFFFF` | `#1C1C1E` | `systemBackground` (elevated) |
| `text.primary` | `#000000` | `#FFFFFF` | `label` |
| `text.secondary` | `rgba(60,60,67,0.6)` | `rgba(235,235,245,0.6)` | `secondaryLabel` |
| `fill.secondary` (icon disc bg) | `rgba(120,120,128,0.16)` | `rgba(120,120,128,0.32)` | `secondarySystemFill` |
| `separator.opaque` (grabber) | `rgba(60,60,67,0.29)` | `rgba(84,84,88,0.65)` | `opaqueSeparator` |
| `tint.primary` (CTA bg) | `#0a7ea4` | `#0a7ea4` | (app brand — keep consistent across modes; reconsider in Phase 2) |
| `text.onTint` (CTA label) | `#FFFFFF` | `#FFFFFF` | n/a |
| `state.error` | `#D70015` | `#FF453A` | `systemRed` |
| `backdrop` | `rgba(0,0,0,0.32)` | `rgba(0,0,0,0.4)` | UIKit modal scrim |

Color scheme source: `useColorScheme()` from `react-native`. Do not read directly from `Appearance` — the hook re-renders on change.

The CTA tint stays brand-blue `#0a7ea4` in both modes for Phase 1 to match `app/(auth)/sign-in.tsx` and `AppearanceSheet.tsx`. Phase 2 may revisit this to match iOS `systemBlue` in dark mode (`#5AC8FA`).

---

## 9. Wiring contract (for coder + architect)

The sheet itself is **dumb** — it reads from state and dispatches actions. State lives in `useAuthStore`. Architect agent designs the slice; this is the surface area the sheet expects:

```
// extensions to authStore
premiumGateOpen: boolean
premiumGateFeature: PremiumFeature | null
openPremiumGate(feature: PremiumFeature): void   // sets both, fires haptic in component effect
closePremiumGate(): void                          // clears both
```

Mount once at root: `app/_layout.tsx` (sibling of existing route stack). Outside the route tree so it floats above any reader screen.

Trigger sites (Phase 1 wiring, separate from spec):
- `components/TTSControls.tsx` — play button checks `useAuthStore.isAuthenticated`; if false, calls `openPremiumGate('tts')` instead of starting playback
- `components/VoiceMicButton.tsx` and `components/RealtimeVoiceButton.tsx` — same pattern with `'voice-chat'`
- `app/chat/[bookId].tsx` send action — `'ai-chat'`
- `components/SyncStatusIndicator.tsx` "Sign in to sync" affordance — `'sync'`

The `useRequireAuth(feature)` hook returns `(action: () => void) => void` — runs the action if authenticated, otherwise calls `openPremiumGate(feature)`. Sheet does not need to know about action continuations in Phase 1 (the user will manually re-tap after signing in; deferred-action continuation is a Phase 6 polish item).

---

## 10. Files the coder will create

- `apps/mobile/components/auth/PremiumFeatureSheet.tsx` — the sheet
- `apps/mobile/components/auth/useRequireAuth.ts` — the hook
- `packages/shared/src/auth-gating/index.ts` — barrel
- `packages/shared/src/auth-gating/types.ts` — `PremiumFeature` enum
- `packages/shared/src/auth-gating/featureCopy.ts` — the title/body table (Section 2)
- `packages/shared/src/auth-gating/shouldGate.ts` — `(user, feature) => boolean`

Files modified, not created:
- `apps/mobile/lib/stores/authStore.ts` — add the four fields/actions in Section 9
- `apps/mobile/app/_layout.tsx` — mount `<PremiumFeatureSheet />` at root
- `apps/rishi-electron/src/renderer/src/components/auth/features.ts` — re-export from `@rishi/shared/auth-gating`, keep electron's icon/bullet additions as electron-only fields
- `apps/rishi-electron/src/renderer/src/components/auth/PremiumFeatureDialog.tsx` — consume shared `featureCopy.title/body`, keep its own bullets layer

---

## 11. Out of scope for Phase 1 (deferred)

- Continuing the original action after sign-in (re-trigger TTS play, etc.) — Phase 6 polish
- Email/password from the sheet — keep on the full screen
- "Use a different account" — not needed
- Provider picker — single CTA per platform, by design
- Apple Sign In end-to-end on iOS if `signIn('apple')` is not yet implemented — fall back per Section 1 note
- Animated icon glyph in the disc — static for Phase 1

---

## 12. Acceptance criteria (designer hand-off)

The coder may ship Phase 1 when:

1. Tapping TTS play on a signed-out session opens the sheet with title `Sign in to listen`, body matches Section 2, icon `headset-outline`
2. CTA label is `Continue with Apple` on iOS simulator, `Continue with Google` on Android emulator
3. CTA opens the in-app OAuth browser via existing `signIn(provider)`; the existing `(auth)/sign-in.tsx` is unchanged
4. While `isAuthenticating === true`, CTA shows spinner and is disabled
5. On worker rejection (not cancel), inline error appears, sheet shakes once, error haptic fires
6. Backdrop tap, pan-down (30% / 500 px/s), and Not now all dismiss the sheet
7. VoiceOver focused on the title speaks `<title>. <body>` after open
8. Reduce Motion replaces spring with 250ms linear and replaces shake with opacity flash
9. Dark mode renders Section 8 token values
10. Electron's `PremiumFeatureDialog` still renders identically to current main (only its copy source changed)
11. `pnpm -C packages/shared test` and `pnpm -C apps/mobile test` green
12. `pnpm -C apps/rishi-electron typecheck` green
