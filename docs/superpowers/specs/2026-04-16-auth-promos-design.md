# Auth Promos (Welcome Modal, Sign-In Banner, Premium Dialog)

**Date:** 2026-04-16
**Scope:** `apps/main` (Tauri desktop) only
**Status:** Design

## Problem

The desktop app's premium features (TTS, AI chat, voice input) are gated by an existing
`useRequireAuth` hook, but the dialog is a single generic message — it doesn't
explain *why* the user should sign in or *what* each feature unlocks. There is also
no prompt on app launch: a brand-new user sees no sign-in guidance unless they
happen to click a gated control, and a returning unauthenticated user has no
passive reminder that signing in unlocks features.

## Goals

1. A first-launch **welcome modal** that introduces sign-in as the path to premium features.
2. A persistent **subtle banner** that reappears on every cold start until the user signs in, dismissible per-session.
3. A **feature-specific premium dialog** that replaces the existing generic one, showing copy tailored to the action the user attempted (TTS, chat, voice input, etc).
4. Share a single OAuth launch path across all four sign-in surfaces (header button, modal, banner, dialog).

## Non-Goals

- Billing, plan tiers, Stripe — "premium" here means "requires an account". The same gating semantics as today's `useRequireAuth`.
- Mobile or web apps — mobile already has a dedicated `(auth)` route group.
- Any toast/notification infrastructure for sign-in errors (not justified by this feature alone).
- E2E / Tauri-integration tests for the promo UI.

## High-Level Approach

Three new React components plus a small feature registry, all wired together by
derived jotai atoms. No Rust changes. The welcome-seen flag lives in
`localStorage`; everything else is session-scoped.

### File layout

All paths relative to `apps/main/src`:

```
components/
  auth/
    WelcomeModal.tsx           (new) First-launch hero modal
    SignInBanner.tsx           (new) Persistent bottom-left card
    PremiumFeatureDialog.tsx   (new) Extracted from useRequireAuth, renders feature-specific copy
    features.ts                (new) Feature registry (title/description/bullets/icon per key)
  atoms/
    authPromo.ts               (new) jotai atoms for promo UI visibility
hooks/
  useHydrateAuth.tsx           (new) Root-level hook: initial user load + deep-link listener
  useRequireAuth.tsx           (modified) Accepts a `feature` param; delegates UI to <PremiumFeatureDialog/>
modules/
  auth.ts                      (modified) Add startSignInFlow() helper
routes/
  __root.tsx                   (modified) Call useHydrateAuth(); mount <WelcomeModal/> + <SignInBanner/>
components/
  LoginButton.tsx              (modified) Remove inline hydration + deep-link listener; call startSignInFlow()
```

## State Model

### Persistent state — `localStorage`

| Key                  | Values        | Purpose                                        |
| -------------------- | ------------- | ---------------------------------------------- |
| `rishi:welcome-seen` | `"1"` or absent | Set once the welcome modal has been shown+closed by any means. |

Accessed only through a thin wrapper in `atoms/authPromo.ts` that try/catches
both read and write. On any localStorage failure, treat `welcomeSeen` as `true`
(fail-closed: prefer silence over showing the modal repeatedly to a user whose
state we can't persist).

### Session state — jotai atoms (`atoms/authPromo.ts`)

```ts
export const authHydratedAtom = atom(false);       // set true once getUserFromStore() resolves
export const welcomeSeenAtom = atom(false);        // hydrated from localStorage on mount
export const bannerDismissedAtom = atom(false);    // in-memory only; resets each cold start

export const showWelcomeModalAtom = atom((get) =>
  get(authHydratedAtom) && !get(isLoggedInAtom) && !get(welcomeSeenAtom)
);

export const showSignInBannerAtom = atom((get) =>
  get(authHydratedAtom) &&
  !get(isLoggedInAtom) &&
  get(welcomeSeenAtom) &&
  !get(bannerDismissedAtom)
);
```

### Write paths

| Event                                 | Writes                                                                      |
| ------------------------------------- | --------------------------------------------------------------------------- |
| Welcome modal closed (any path)       | `welcomeSeenAtom = true`, `localStorage.setItem("rishi:welcome-seen", "1")` |
| Welcome modal "Maybe later"           | Above, plus `bannerDismissedAtom = true` for current session                |
| Welcome modal "Sign in"               | Above (except banner-dismissed stays false), then `startSignInFlow()`       |
| Banner X button                       | `bannerDismissedAtom = true` (atom only — resets next launch)               |
| OAuth callback completes              | `userAtom = user` → both derived atoms flip to `false` automatically        |

### Hydration gate

`showWelcomeModalAtom` and `showSignInBannerAtom` both gate on `authHydratedAtom`
to prevent the modal from flashing in front of a user whose keychain token is
still being read. `useHydrateAuth()` sets `authHydratedAtom = true` in the
`finally` block of its initial `getUserFromStore()` call, matching the
`isLoading` pattern currently in `LoginButton.tsx`.

## Feature Registry

`components/auth/features.ts`:

```ts
export type PremiumFeature = "tts" | "chat" | "voice-input" | "ai-generic";

export const PREMIUM_FEATURES: Record<PremiumFeature, {
  icon: LucideIcon;
  title: string;
  description: string;
  bullets: string[];
}> = {
  tts: {
    icon: Volume2,
    title: "Listen to your books",
    description: "AI-powered text-to-speech turns any book into an audiobook.",
    bullets: [
      "Natural, expressive voices",
      "Reads EPUB, PDF, MOBI, DjVu",
      "Remembers your spot across devices",
    ],
  },
  chat: {
    icon: MessageSquare,
    title: "Chat with your books",
    description: "Ask questions, get summaries, explore ideas with an AI that knows your library.",
    bullets: [
      "Cites passages from the book you're reading",
      "Works across your entire library",
      "Remembers context within a conversation",
    ],
  },
  "voice-input": {
    icon: Mic,
    title: "Talk to your books",
    description: "Ask questions hands-free with voice input.",
    bullets: [
      "Natural speech recognition",
      "Paired with AI book chat",
    ],
  },
  "ai-generic": {
    icon: Sparkles,
    title: "AI features require an account",
    description: "Sign in to unlock Rishi's AI-powered reading tools.",
    bullets: [],
  },
};
```

## Component Specs

### `<PremiumFeatureDialog />`

Controlled modal. Props:
- `open: boolean`
- `onOpenChange: (open: boolean) => void`
- `feature: PremiumFeature`

Layout: icon + title + description + bulleted list (if any) + footer with
**Maybe later** (secondary, closes) and **Sign in** (primary, calls
`startSignInFlow()` and closes). Uses the existing `Dialog` primitives from
`@components/components/ui/dialog`.

### `<WelcomeModal />`

Reads `showWelcomeModalAtom`. Larger / more spacious than `PremiumFeatureDialog`.
Content is the app-level value prop (generic, not feature-specific). Two
actions:

- **Sign in** → `setWelcomeSeen(true)` + `startSignInFlow()`
- **Maybe later** → `setWelcomeSeen(true)` + `setBannerDismissed(true)`

Both close the modal.

### `<SignInBanner />`

Reads `showSignInBannerAtom`. Fixed-position floating card in the bottom-left,
near the existing `SyncStatusIndicator` (already at `bottom-4 left-4`). The
banner sits directly above the indicator with consistent spacing.

Contents: small icon + one-line message ("Sign in to unlock AI features") +
**Sign in** button + dismiss X. X calls `setBannerDismissed(true)` only (no
persistence).

### `useRequireAuth` — updated

```ts
export function useRequireAuth() {
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const [open, setOpen] = useState(false);
  const [feature, setFeature] = useState<PremiumFeature>("ai-generic");

  const requireAuth = useCallback(
    (f: PremiumFeature, action: () => void) => {
      if (isLoggedIn) {
        action();
      } else {
        setFeature(f);
        setOpen(true);
      }
    },
    [isLoggedIn],
  );

  const AuthDialog = (
    <PremiumFeatureDialog open={open} onOpenChange={setOpen} feature={feature} />
  );

  return { requireAuth, AuthDialog };
}
```

### `useHydrateAuth()`

Called exactly once, from `__root.tsx`. Responsibilities:

1. On mount, read `localStorage["rishi:welcome-seen"]` and set `welcomeSeenAtom`.
2. Call `getUserFromStore()` in the background; set `userAtom` on success, null
   on failure; set `authHydratedAtom = true` in `finally`.
3. Register the `onOpenUrl` deep-link listener currently in `LoginButton.tsx`,
   with the same retry logic. On successful `completeAuth`, update `userAtom`.
4. Clean up the listener on unmount.

This hook replaces the two `useEffect`s in `LoginButton.tsx`. `LoginButton`
becomes purely presentational: reads `userAtom` / `isLoggedInAtom`, shows the
right UI, its `login()` calls `startSignInFlow()` and its `logout()` calls
`signout()`.

### `startSignInFlow()` in `modules/auth.ts`

```ts
export async function startSignInFlow(): Promise<void> {
  try {
    const { state, codeChallenge } = await getState();
    await openUrl(
      `https://rishi.fidexa.org?login=true&state=${encodeURIComponent(state)}` +
      `&code_challenge=${encodeURIComponent(codeChallenge)}`
    );
  } catch (err) {
    console.error("Failed to start sign-in flow:", err);
  }
}
```

All four surfaces (`LoginButton`, `WelcomeModal`, `SignInBanner`, `PremiumFeatureDialog`)
call this helper. The deep-link listener in `useHydrateAuth()` handles the
callback regardless of which surface initiated the flow.

## Lifecycle

### First-ever launch (unauthenticated user)

1. `__root.tsx` mounts → `useHydrateAuth()` fires.
2. Initial render: `authHydratedAtom = false` → nothing visible.
3. `getUserFromStore()` resolves with `null` → `authHydratedAtom = true`, `userAtom = null`.
4. `localStorage["rishi:welcome-seen"]` is absent → `welcomeSeenAtom = false`.
5. `showWelcomeModalAtom = true` → `<WelcomeModal>` renders.
6. User clicks **Sign in** → flag persisted + OAuth URL opens in browser.
7. User completes OAuth → deep-link callback → `userAtom = user` → both derived atoms become false.

### First launch, user dismisses with "Maybe later"

1. Steps 1–5 as above.
2. User clicks **Maybe later** → `welcomeSeenAtom = true` + `localStorage` set + `bannerDismissedAtom = true`.
3. Both derived atoms are false for the rest of the session (banner suppressed immediately after explicit dismissal to avoid feeling pushy).
4. Next cold start: `welcomeSeenAtom = true` (from localStorage), `bannerDismissedAtom = false` (session reset) → `<SignInBanner>` renders.

### Returning unauthenticated user

1. `useHydrateAuth()` hydrates: `userAtom = null`, `welcomeSeenAtom = true`.
2. `<WelcomeModal>` stays closed; `<SignInBanner>` renders near `SyncStatusIndicator`.
3. User clicks banner X → hidden for this session only.

### Returning authenticated user

1. `useHydrateAuth()` hydrates: `userAtom = user` (from keychain).
2. Both derived atoms are false → nothing promo-related renders.

## Call-Site Migration

Existing consumers of `useRequireAuth`:

| File                                             | New call                                     |
| ------------------------------------------------ | -------------------------------------------- |
| `components/TTSControls.tsx`                     | `requireAuth("tts", action)`                 |
| `components/epub.tsx`                            | `requireAuth("tts", action)` for play paths, `requireAuth("chat", action)` for chat paths — one per call site |
| `components/djvu/DjvuView.tsx`                   | Same split as above                          |
| `components/mobi/MobiView.tsx`                   | Same split as above                          |

The exact feature key per call site depends on which action is being gated at
that site; this is resolved at plan-writing time by inspecting each handler.

## Error Handling

- **localStorage unavailable / quota errors:** Wrap read/write in try/catch. On
  error, treat `welcomeSeen = true` and log once via `console.warn`. The modal
  will not show, the banner will; the user can still sign in from the banner
  or the header button.
- **`startSignInFlow()` failure:** try/catch inside the helper; log to
  `console.error`. No UI feedback — the user can retry from any surface.
  Justification: no existing toast system in the app; adding one is out of
  scope for this feature.
- **Deep-link callback failures:** Preserved from existing `LoginButton.tsx`
  logic (retry with backoff, 409 special-case, max retries). Moved verbatim
  into `useHydrateAuth()`.

## Testing

**Unit (`vitest`, matches existing `epubwrapper.browser.test.tsx` pattern):**

- `features.ts` — snapshot test of the registry, so copy changes are explicit and reviewable.
- `atoms/authPromo.ts` — truth table for `showWelcomeModalAtom` and `showSignInBannerAtom` across all combinations of `authHydrated × isLoggedIn × welcomeSeen × bannerDismissed`.
- `useRequireAuth` — gating logic: logged-in users have their action invoked directly; logged-out users see the dialog open with the feature they passed.

**Component:**

- `WelcomeModal` — renders only when atoms indicate it should; **Sign in** button calls `startSignInFlow` + sets welcomeSeen; **Maybe later** sets welcomeSeen AND session banner-dismissed.
- `SignInBanner` — renders only when atoms indicate it should; X only updates `bannerDismissedAtom` (no localStorage write).
- `PremiumFeatureDialog` — renders the correct title/description/bullets for each feature key.

**Not tested at this level:**

- The OAuth deep-link callback path (already untested; out of scope).
- Tauri-integration / e2e flows.

## Security Considerations

- `localStorage` key is a non-sensitive UI preference. No PII, no tokens.
- `startSignInFlow()` opens the same URL format already in use by `LoginButton.tsx`; no new attack surface.
- Deep-link state validation logic is moved verbatim from `LoginButton.tsx` to `useHydrateAuth()` with no changes.

## Rollout / Compatibility

- No schema changes, no migration.
- Existing users of the app will see the banner on their next launch (their
  `rishi:welcome-seen` key is absent, so they'll see the welcome modal once).
  This is acceptable: a returning user getting the modal once is a reasonable
  introduction to the promo flow.
- `useRequireAuth()`'s signature changes from `(action)` to `(feature, action)`.
  All four existing call sites are updated in the same change. No
  backwards-compatibility shim.

## Open Questions

None at this point. The plan document (written next) will pin down the exact
feature key per existing call site in `epub.tsx` / `djvu/DjvuView.tsx` /
`mobi/MobiView.tsx` / `TTSControls.tsx`.
