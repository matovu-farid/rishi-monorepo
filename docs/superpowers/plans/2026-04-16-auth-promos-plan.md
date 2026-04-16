# Auth Promos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-launch welcome modal, a persistent bottom-left sign-in banner, and a feature-specific premium dialog to `apps/main` (Tauri desktop) — all sharing one OAuth launch path.

**Architecture:** Three new React components driven by jotai atoms. Persistent welcome-seen flag in `localStorage`; session-only banner-dismissed flag in memory. A new root-level `useHydrateAuth()` hook owns initial user load + deep-link callback (extracted from `LoginButton.tsx`). No Rust changes.

**Tech Stack:** React 19, jotai 2, Tauri 2 (`@tauri-apps/plugin-opener`, `@tauri-apps/plugin-deep-link`), Radix Dialog, lucide-react, vitest + jotai `createStore` for tests.

**Spec:** `docs/superpowers/specs/2026-04-16-auth-promos-design.md`

---

## File Structure

All paths relative to `apps/main/src` unless noted.

| File | Purpose | Status |
| --- | --- | --- |
| `components/auth/features.ts` | Premium feature registry (icon/title/description/bullets per key) | New |
| `components/auth/features.test.ts` | Snapshot test of registry | New |
| `components/auth/PremiumFeatureDialog.tsx` | Feature-specific gating dialog | New |
| `components/auth/WelcomeModal.tsx` | First-launch hero modal | New |
| `components/auth/SignInBanner.tsx` | Persistent bottom-left card | New |
| `atoms/authPromo.ts` | Promo UI atoms + writable atoms with localStorage side effects | New |
| `atoms/authPromo.test.ts` | Truth table for derived atoms + write-path tests | New |
| `hooks/useHydrateAuth.tsx` | Root-level: initial `getUserFromStore` + deep-link listener | New |
| `hooks/useRequireAuth.tsx` | Updated signature `(feature, action)`; delegates UI to `<PremiumFeatureDialog/>` | Modify |
| `modules/auth.ts` | Add `startSignInFlow()` helper | Modify |
| `routes/__root.tsx` | Call `useHydrateAuth()`; mount `<WelcomeModal/>` + `<SignInBanner/>` | Modify |
| `components/LoginButton.tsx` | Remove inline hydration + deep-link listener; call `startSignInFlow()` | Modify |
| `components/TTSControls.tsx` | `requireAuth("tts", ...)` and `requireAuth("voice-input", ...)` | Modify |
| `components/epub.tsx` | `requireAuth("chat", ...)` | Modify |
| `components/djvu/DjvuView.tsx` | `requireAuth("chat", ...)` | Modify |
| `components/mobi/MobiView.tsx` | `requireAuth("chat", ...)` | Modify |

---

## Task 1: Feature Registry

**Files:**
- Create: `apps/main/src/components/auth/features.ts`
- Test: `apps/main/src/components/auth/features.test.ts`

- [ ] **Step 1: Write failing snapshot test**

Create `apps/main/src/components/auth/features.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { PREMIUM_FEATURES, type PremiumFeature } from "./features";

describe("PREMIUM_FEATURES registry", () => {
  it("exposes all expected feature keys", () => {
    const keys: PremiumFeature[] = ["tts", "chat", "voice-input", "ai-generic"];
    for (const k of keys) {
      expect(PREMIUM_FEATURES[k]).toBeDefined();
    }
  });

  it("each feature has icon, title, description, bullets", () => {
    for (const [key, val] of Object.entries(PREMIUM_FEATURES)) {
      expect(val.icon, `${key}.icon`).toBeDefined();
      expect(val.title, `${key}.title`).toBeTruthy();
      expect(val.description, `${key}.description`).toBeTruthy();
      expect(Array.isArray(val.bullets), `${key}.bullets`).toBe(true);
    }
  });

  it("matches snapshot of titles and descriptions", () => {
    const summary = Object.fromEntries(
      Object.entries(PREMIUM_FEATURES).map(([k, v]) => [
        k,
        { title: v.title, description: v.description, bullets: v.bullets },
      ]),
    );
    expect(summary).toMatchSnapshot();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/main && npx vitest run src/components/auth/features.test.ts
```

Expected: FAIL — `Cannot find module './features'`.

- [ ] **Step 3: Create the registry**

Create `apps/main/src/components/auth/features.ts`:

```ts
import { Volume2, MessageSquare, Mic, Sparkles, type LucideIcon } from "lucide-react";

export type PremiumFeature = "tts" | "chat" | "voice-input" | "ai-generic";

export interface PremiumFeatureConfig {
  icon: LucideIcon;
  title: string;
  description: string;
  bullets: string[];
}

export const PREMIUM_FEATURES: Record<PremiumFeature, PremiumFeatureConfig> = {
  tts: {
    icon: Volume2,
    title: "Listen to your books",
    description: "AI-powered text-to-speech turns any book into an audiobook.",
    bullets: [
      "Natural, expressive voices",
      "Reads EPUB, PDF, MOBI, and DjVu",
      "Remembers your spot across devices",
    ],
  },
  chat: {
    icon: MessageSquare,
    title: "Chat with your books",
    description:
      "Ask questions, get summaries, and explore ideas with an AI that knows your library.",
    bullets: [
      "Cites passages from the book you're reading",
      "Works across your entire library",
      "Remembers context within a conversation",
    ],
  },
  "voice-input": {
    icon: Mic,
    title: "Talk to your books",
    description: "Ask questions hands-free with realtime voice conversations.",
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

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/main && npx vitest run src/components/auth/features.test.ts
```

Expected: PASS (3 tests). On first run vitest will write the snapshot file.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/auth/features.ts \
        apps/main/src/components/auth/features.test.ts \
        apps/main/src/components/auth/__snapshots__/features.test.ts.snap
git commit -m "feat(main): add premium feature registry for auth promos"
```

---

## Task 2: AuthPromo Atoms (state model)

**Files:**
- Create: `apps/main/src/atoms/authPromo.ts`
- Test: `apps/main/src/atoms/authPromo.test.ts`

This task introduces the `apps/main/src/atoms/` directory (currently atoms live under `components/pdf/atoms/`). Top-level `atoms/` is the right home for cross-cutting promo state used by root-mounted UI.

- [ ] **Step 1: Write failing test for derived visibility atoms**

Create `apps/main/src/atoms/authPromo.test.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "jotai";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  welcomeSeenAtom,
  bannerDismissedAtom,
  showWelcomeModalAtom,
  showSignInBannerAtom,
  setWelcomeSeenAtom,
  dismissBannerAtom,
  dismissWelcomeAtom,
  hydrateWelcomeSeenAtom,
  WELCOME_SEEN_KEY,
} from "./authPromo";

const FAKE_USER = { id: "u1", firstName: "T" } as any;

function makeStore() {
  return createStore();
}

describe("showWelcomeModalAtom", () => {
  it("is false before hydration regardless of other state", () => {
    const s = makeStore();
    s.set(authHydratedAtom, false);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });

  it("is true when hydrated, logged out, and welcome unseen", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(true);
  });

  it("is false when logged in", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, FAKE_USER);
    s.set(welcomeSeenAtom, false);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });

  it("is false when welcome already seen", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    expect(s.get(showWelcomeModalAtom)).toBe(false);
  });
});

describe("showSignInBannerAtom", () => {
  it("is false before hydration", () => {
    const s = makeStore();
    s.set(authHydratedAtom, false);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is true when hydrated, logged out, welcome seen, banner not dismissed", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(true);
  });

  it("is false when welcome modal hasn't been seen yet", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, false);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is false when banner dismissed for session", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, null);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, true);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });

  it("is false when logged in", () => {
    const s = makeStore();
    s.set(authHydratedAtom, true);
    s.set(userAtom, FAKE_USER);
    s.set(welcomeSeenAtom, true);
    s.set(bannerDismissedAtom, false);
    expect(s.get(showSignInBannerAtom)).toBe(false);
  });
});

describe("write-path atoms", () => {
  beforeEach(() => {
    localStorage.clear();
    vi.restoreAllMocks();
  });

  it("setWelcomeSeenAtom flips atom and writes localStorage", () => {
    const s = makeStore();
    s.set(setWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBe("1");
  });

  it("setWelcomeSeenAtom still flips atom even if localStorage write throws", () => {
    const s = makeStore();
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    s.set(setWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(warn).toHaveBeenCalled();
  });

  it("dismissBannerAtom only sets session atom, no localStorage write", () => {
    const s = makeStore();
    s.set(dismissBannerAtom);
    expect(s.get(bannerDismissedAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBeNull();
  });

  it("dismissWelcomeAtom sets both welcomeSeen (persisted) and bannerDismissed (session)", () => {
    const s = makeStore();
    s.set(dismissWelcomeAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
    expect(s.get(bannerDismissedAtom)).toBe(true);
    expect(localStorage.getItem(WELCOME_SEEN_KEY)).toBe("1");
  });

  it("hydrateWelcomeSeenAtom reads localStorage into the atom", () => {
    const s = makeStore();
    localStorage.setItem(WELCOME_SEEN_KEY, "1");
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
  });

  it("hydrateWelcomeSeenAtom fail-closes (treats welcomeSeen=true) when localStorage throws", () => {
    const s = makeStore();
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("denied");
    });
    vi.spyOn(console, "warn").mockImplementation(() => {});
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(true);
  });

  it("hydrateWelcomeSeenAtom leaves atom false when localStorage absent", () => {
    const s = makeStore();
    s.set(hydrateWelcomeSeenAtom);
    expect(s.get(welcomeSeenAtom)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/main && npx vitest run src/atoms/authPromo.test.ts
```

Expected: FAIL — `Cannot find module './authPromo'`.

- [ ] **Step 3: Create the atoms module**

Create `apps/main/src/atoms/authPromo.ts`:

```ts
import { atom } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";

export const WELCOME_SEEN_KEY = "rishi:welcome-seen";

// --- Primitive atoms ---

/** True once the initial getUserFromStore() resolves (success or failure). */
export const authHydratedAtom = atom(false);

/** True once the welcome modal has been shown+closed. Hydrated from localStorage. */
export const welcomeSeenAtom = atom(false);

/** Session-only: banner dismissed for the current run. Resets on cold start. */
export const bannerDismissedAtom = atom(false);

// --- Derived visibility atoms ---

export const showWelcomeModalAtom = atom((get) =>
  get(authHydratedAtom) && !get(isLoggedInAtom) && !get(welcomeSeenAtom),
);

export const showSignInBannerAtom = atom((get) =>
  get(authHydratedAtom) &&
  !get(isLoggedInAtom) &&
  get(welcomeSeenAtom) &&
  !get(bannerDismissedAtom),
);

// --- Write-path atoms (each is a write-only atom for clean side effects) ---

/** Mark welcome-seen: updates atom AND writes localStorage. Fail-closed on storage errors. */
export const setWelcomeSeenAtom = atom(null, (_get, set) => {
  try {
    localStorage.setItem(WELCOME_SEEN_KEY, "1");
  } catch (err) {
    console.warn("[authPromo] failed to persist welcome-seen flag:", err);
  }
  set(welcomeSeenAtom, true);
});

/** Dismiss banner for current session only (no localStorage write). */
export const dismissBannerAtom = atom(null, (_get, set) => {
  set(bannerDismissedAtom, true);
});

/**
 * "Maybe later" on welcome modal: persist welcome-seen AND suppress banner
 * for the current session (so the user isn't immediately re-prompted).
 */
export const dismissWelcomeAtom = atom(null, (_get, set) => {
  set(setWelcomeSeenAtom);
  set(bannerDismissedAtom, true);
});

/**
 * Read localStorage on app boot and seed welcomeSeenAtom.
 * Fail-closed: on any read error, treat welcomeSeen=true to avoid showing the
 * modal repeatedly to a user whose state we can't persist.
 */
export const hydrateWelcomeSeenAtom = atom(null, (_get, set) => {
  try {
    const value = localStorage.getItem(WELCOME_SEEN_KEY);
    set(welcomeSeenAtom, value === "1");
  } catch (err) {
    console.warn("[authPromo] failed to read welcome-seen flag, fail-closing:", err);
    set(welcomeSeenAtom, true);
  }
});
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/main && npx vitest run src/atoms/authPromo.test.ts
```

Expected: PASS (all 14 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/atoms/authPromo.ts apps/main/src/atoms/authPromo.test.ts
git commit -m "feat(main): add auth promo atoms with localStorage persistence"
```

---

## Task 3: `startSignInFlow` helper in `modules/auth.ts`

**Files:**
- Modify: `apps/main/src/modules/auth.ts`

This extracts the OAuth URL launch from `LoginButton.tsx:139-147` into a reusable helper. We do NOT delete code from `LoginButton.tsx` in this task — that happens in Task 9 to keep the change atomic.

- [ ] **Step 1: Read the existing module**

```bash
cat apps/main/src/modules/auth.ts
```

Confirm it contains only `getAuthToken()`.

- [ ] **Step 2: Append `startSignInFlow` to the module**

Edit `apps/main/src/modules/auth.ts`, appending after the existing `getAuthToken` export:

```ts
import { openUrl } from "@tauri-apps/plugin-opener";
import { getState } from "@/generated";

/**
 * Open the Rishi sign-in URL in the user's default browser. Generates a fresh
 * OAuth state + code_challenge for each call. Errors are logged but not
 * thrown — callers may invoke this from passive UI (banner, modal) where
 * surfacing a failure is worse than silently failing.
 *
 * The OAuth callback is handled by the deep-link listener in useHydrateAuth().
 */
export async function startSignInFlow(): Promise<void> {
  try {
    const { state, codeChallenge } = await getState();
    await openUrl(
      `https://rishi.fidexa.org?login=true` +
        `&state=${encodeURIComponent(state)}` +
        `&code_challenge=${encodeURIComponent(codeChallenge)}`,
    );
  } catch (err) {
    console.error("[auth] failed to start sign-in flow:", err);
  }
}
```

The existing `import { invoke } ...` and `getAuthToken()` stay untouched at the top.

- [ ] **Step 3: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no errors related to `modules/auth.ts`. (Pre-existing errors elsewhere are out of scope; the diff under review must not introduce new ones.)

- [ ] **Step 4: Commit**

```bash
git add apps/main/src/modules/auth.ts
git commit -m "feat(main): extract startSignInFlow helper into modules/auth"
```

---

## Task 4: `useHydrateAuth` hook

**Files:**
- Create: `apps/main/src/hooks/useHydrateAuth.tsx`

This hook will replace the two `useEffect`s currently in `LoginButton.tsx` (initial keychain load + deep-link listener). We create it now but do NOT call it yet — it's wired into `__root.tsx` in Task 11, and `LoginButton.tsx` keeps its current effects until that task removes them, so the app remains functional after each commit.

- [ ] **Step 1: Create the hook**

Create `apps/main/src/hooks/useHydrateAuth.tsx`:

```tsx
import { useEffect, useRef } from "react";
import { useSetAtom } from "jotai";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import {
  getUserFromStore,
  getState,
  completeAuth,
  checkAuthStatus,
} from "@/generated";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  hydrateWelcomeSeenAtom,
} from "@/atoms/authPromo";

const MAX_AUTH_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;

/**
 * Root-level hook: runs exactly once on app mount.
 *
 * 1. Hydrates `welcomeSeenAtom` from localStorage.
 * 2. Loads the user from the OS keychain into `userAtom`; sets
 *    `authHydratedAtom = true` in `finally` so promo UI can decide what to show.
 * 3. Registers the OAuth deep-link callback listener with retry/backoff
 *    matching the previous logic in LoginButton.tsx.
 */
export function useHydrateAuth(): void {
  const setUser = useSetAtom(userAtom);
  const setAuthHydrated = useSetAtom(authHydratedAtom);
  const hydrateWelcomeSeen = useSetAtom(hydrateWelcomeSeenAtom);

  // Lazy state for OAuth — generated when needed (login click or callback).
  const stateRef = useRef<string | null>(null);
  const codeChallengeRef = useRef<string | null>(null);

  // 1 + 2: hydrate localStorage + keychain user.
  useEffect(() => {
    hydrateWelcomeSeen();

    void (async () => {
      try {
        const user = await getUserFromStore();
        setUser(user);
      } catch (err) {
        setUser(null);
        console.error("[useHydrateAuth] failed to load user from store:", err);
      } finally {
        setAuthHydrated(true);
      }
    })();
    // run-once on mount
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 3: deep-link OAuth callback listener.
  useEffect(() => {
    async function ensureState() {
      if (!stateRef.current || !codeChallengeRef.current) {
        const result = await getState();
        stateRef.current = result.state;
        codeChallengeRef.current = result.codeChallenge;
      }
    }

    const unlisten = onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          console.error("[useHydrateAuth] malformed deep link URL:", url);
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) continue;

        await ensureState();

        if (callbackState !== stateRef.current) {
          console.error("[useHydrateAuth] auth callback state mismatch — ignoring");
          continue;
        }

        for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
          try {
            const user = await completeAuth({ state: callbackState });
            setUser(user);
            const fresh = await getState();
            stateRef.current = fresh.state;
            codeChallengeRef.current = fresh.codeChallenge;
            return;
          } catch (error) {
            const errMsg = String(error);
            console.error(
              `[useHydrateAuth] auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`,
              error,
            );

            if (
              errMsg.includes("already used") ||
              errMsg.includes("permanently failed") ||
              errMsg.includes("Max retries")
            ) {
              break;
            }

            if (attempt < MAX_AUTH_RETRIES) {
              const is409 = errMsg.includes("409") || errMsg.includes("in progress");
              const delay = is409
                ? BASE_RETRY_DELAY_MS * 3
                : BASE_RETRY_DELAY_MS * attempt;

              try {
                const status = await checkAuthStatus({ state: callbackState });
                if (status.status === "not_found" || status.status === "completed") {
                  break;
                }
              } catch {
                // fall through and retry
              }

              await new Promise((r) => setTimeout(r, delay));
            }
          }
        }
        console.error("[useHydrateAuth] all auth attempts failed");
      }
    });

    return () => {
      void unlisten.then((fn) => fn());
    };
    // run-once on mount
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
```

- [ ] **Step 2: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors related to `useHydrateAuth.tsx`.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/hooks/useHydrateAuth.tsx
git commit -m "feat(main): add useHydrateAuth hook for root-level auth bootstrap"
```

---

## Task 5: `PremiumFeatureDialog` component

**Files:**
- Create: `apps/main/src/components/auth/PremiumFeatureDialog.tsx`

- [ ] **Step 1: Create the component**

Create `apps/main/src/components/auth/PremiumFeatureDialog.tsx`:

```tsx
import { LogIn, Check } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@components/components/ui/dialog";
import { Button } from "@components/components/ui/button";
import { startSignInFlow } from "@/modules/auth";
import { PREMIUM_FEATURES, type PremiumFeature } from "./features";

export interface PremiumFeatureDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  feature: PremiumFeature;
}

export function PremiumFeatureDialog({
  open,
  onOpenChange,
  feature,
}: PremiumFeatureDialogProps): React.JSX.Element {
  const config = PREMIUM_FEATURES[feature];
  const Icon = config.icon;

  async function handleSignIn() {
    onOpenChange(false);
    await startSignInFlow();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <div className="flex items-center gap-3">
            <div className="rounded-full bg-primary/10 p-2">
              <Icon size={20} className="text-primary" />
            </div>
            <DialogTitle>{config.title}</DialogTitle>
          </div>
          <DialogDescription className="pt-2">
            {config.description}
          </DialogDescription>
        </DialogHeader>

        {config.bullets.length > 0 && (
          <ul className="mt-2 space-y-2 text-sm">
            {config.bullets.map((b) => (
              <li key={b} className="flex items-start gap-2">
                <Check size={16} className="mt-0.5 shrink-0 text-primary" />
                <span>{b}</span>
              </li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Maybe later
          </Button>
          <Button onClick={handleSignIn}>
            <LogIn size={16} className="mr-2" />
            Sign in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/auth/PremiumFeatureDialog.tsx
git commit -m "feat(main): add PremiumFeatureDialog component"
```

---

## Task 6: Update `useRequireAuth` to use `PremiumFeatureDialog`

**Files:**
- Modify: `apps/main/src/hooks/useRequireAuth.tsx`

We change the hook signature from `requireAuth(action)` to `requireAuth(feature, action)` in this task. Call sites are migrated in Task 7 — they will be temporarily broken between Tasks 6 and 7. Both tasks must land before merging.

> **No automated test for this hook.** The codebase has neither `@testing-library/react` nor `renderHook` available (the only test infrastructure is `vitest-browser-react.render` for `.browser.test.tsx` files). The hook is 8 lines of trivial branching logic; coverage comes from the atom tests in Task 2 (which exercise `isLoggedInAtom`) plus the manual smoke test in Task 11. Adding `@testing-library/react` for one tiny hook would expand test infrastructure beyond the scope of this feature.

- [ ] **Step 1: Replace the hook implementation**

Replace the entire contents of `apps/main/src/hooks/useRequireAuth.tsx` with:

```tsx
import { useCallback, useState } from "react";
import { useAtomValue } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";
import { PremiumFeatureDialog } from "@/components/auth/PremiumFeatureDialog";
import type { PremiumFeature } from "@/components/auth/features";

/**
 * Gates premium (auth-required) features behind sign-in.
 *
 * Usage:
 *   const { requireAuth, AuthDialog } = useRequireAuth();
 *   <button onClick={() => requireAuth("tts", () => player.play())}>Play</button>
 *   {AuthDialog}
 */
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
    <PremiumFeatureDialog
      open={open}
      onOpenChange={setOpen}
      feature={feature}
    />
  );

  return { requireAuth, AuthDialog };
}
```

- [ ] **Step 2: Verify type errors at the existing call sites are visible**

```bash
cd apps/main && npx tsc --noEmit 2>&1 | grep -E "TTSControls|epub.tsx|MobiView|DjvuView" | head -20
```

Expected: Errors at the 5 call sites complaining `requireAuth` expects 2 arguments. This is the contract Task 7 will fix.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/hooks/useRequireAuth.tsx
git commit -m "feat(main): useRequireAuth accepts feature key, renders PremiumFeatureDialog"
```

---

## Task 7: Migrate `requireAuth` call sites

**Files:**
- Modify: `apps/main/src/components/TTSControls.tsx`
- Modify: `apps/main/src/components/epub.tsx`
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`
- Modify: `apps/main/src/components/mobi/MobiView.tsx`

Five call sites total, mapped per the spec.

- [ ] **Step 1: Update `TTSControls.tsx` — playback gate**

In `apps/main/src/components/TTSControls.tsx`, find the call near line 132:

```tsx
    requireAuth(() => {
      void player.play();
    });
```

Replace with:

```tsx
    requireAuth("tts", () => {
      void player.play();
    });
```

- [ ] **Step 2: Update `TTSControls.tsx` — voice chat toggle**

In the same file, find the call near line 145:

```tsx
    requireAuth(() => {
      void toggleChat();
    });
```

Replace with:

```tsx
    requireAuth("voice-input", () => {
      void toggleChat();
    });
```

(`toggleChat` here flips `isChattingAtom` which gates the realtime voice conversation — `voice-input` is the right key.)

- [ ] **Step 3: Update `epub.tsx` — chat panel**

In `apps/main/src/components/epub.tsx`, find near line 278:

```tsx
          onClick={() => requireAuth(() => setChatPanelOpen(true))}
```

Replace with:

```tsx
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
```

- [ ] **Step 4: Update `djvu/DjvuView.tsx` — chat panel**

In `apps/main/src/components/djvu/DjvuView.tsx`, find near line 341:

```tsx
            onClick={() => requireAuth(() => setChatPanelOpen(true))}
```

Replace with:

```tsx
            onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
```

- [ ] **Step 5: Update `mobi/MobiView.tsx` — chat panel**

In `apps/main/src/components/mobi/MobiView.tsx`, find near line 278:

```tsx
          onClick={() => requireAuth(() => setChatPanelOpen(true))}
```

Replace with:

```tsx
          onClick={() => requireAuth("chat", () => setChatPanelOpen(true))}
```

- [ ] **Step 6: Verify no `requireAuth(` call remains with single argument**

```bash
cd apps/main && grep -rn "requireAuth(" src --include="*.tsx" --include="*.ts" \
  | grep -v "useRequireAuth\|test.tsx\|test.ts\|features.ts" \
  | grep -vE 'requireAuth\("(tts|chat|voice-input|ai-generic)"'
```

Expected: empty output (every remaining call passes a feature key).

- [ ] **Step 7: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no errors at any of the migrated call sites.

- [ ] **Step 8: Commit**

```bash
git add apps/main/src/components/TTSControls.tsx \
        apps/main/src/components/epub.tsx \
        apps/main/src/components/djvu/DjvuView.tsx \
        apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat(main): migrate requireAuth call sites to feature-keyed API"
```

---

## Task 8: `WelcomeModal` component

**Files:**
- Create: `apps/main/src/components/auth/WelcomeModal.tsx`

- [ ] **Step 1: Create the component**

Create `apps/main/src/components/auth/WelcomeModal.tsx`:

```tsx
import { useAtomValue, useSetAtom } from "jotai";
import { Sparkles, LogIn } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@components/components/ui/dialog";
import { Button } from "@components/components/ui/button";
import {
  showWelcomeModalAtom,
  setWelcomeSeenAtom,
  dismissWelcomeAtom,
} from "@/atoms/authPromo";
import { startSignInFlow } from "@/modules/auth";

/**
 * First-launch hero modal. Visible only when authHydrated && !isLoggedIn && !welcomeSeen.
 * Mounted once at the root level.
 */
export function WelcomeModal(): React.JSX.Element {
  const open = useAtomValue(showWelcomeModalAtom);
  const setWelcomeSeen = useSetAtom(setWelcomeSeenAtom);
  const dismissWelcome = useSetAtom(dismissWelcomeAtom);

  async function handleSignIn() {
    setWelcomeSeen();
    await startSignInFlow();
  }

  function handleMaybeLater() {
    dismissWelcome();
  }

  function handleOpenChange(next: boolean) {
    if (!next) dismissWelcome();
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <div className="mx-auto mb-2 rounded-full bg-primary/10 p-3">
            <Sparkles size={28} className="text-primary" />
          </div>
          <DialogTitle className="text-center text-xl">
            Welcome to Rishi
          </DialogTitle>
          <DialogDescription className="pt-2 text-center">
            Sign in to unlock AI-powered text-to-speech, chat with your books,
            and sync your library across devices.
          </DialogDescription>
        </DialogHeader>

        <DialogFooter className="sm:justify-center">
          <Button variant="outline" onClick={handleMaybeLater}>
            Maybe later
          </Button>
          <Button onClick={handleSignIn}>
            <LogIn size={16} className="mr-2" />
            Sign in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/auth/WelcomeModal.tsx
git commit -m "feat(main): add first-launch WelcomeModal component"
```

---

## Task 9: `SignInBanner` component

**Files:**
- Create: `apps/main/src/components/auth/SignInBanner.tsx`

- [ ] **Step 1: Create the component**

Create `apps/main/src/components/auth/SignInBanner.tsx`:

```tsx
import { useAtomValue, useSetAtom } from "jotai";
import { Sparkles, X, LogIn } from "lucide-react";
import { Button } from "@components/components/ui/button";
import {
  showSignInBannerAtom,
  dismissBannerAtom,
} from "@/atoms/authPromo";
import { startSignInFlow } from "@/modules/auth";

/**
 * Persistent bottom-left card prompting unauthenticated returning users to
 * sign in. Mounted once at the root; positions itself just above the existing
 * SyncStatusIndicator.
 */
export function SignInBanner(): React.JSX.Element | null {
  const visible = useAtomValue(showSignInBannerAtom);
  const dismiss = useSetAtom(dismissBannerAtom);

  if (!visible) return null;

  return (
    <div
      className="fixed bottom-16 left-4 z-50 flex w-72 items-center gap-3 rounded-lg border bg-background/95 p-3 shadow-md backdrop-blur"
      role="region"
      aria-label="Sign-in promotion"
    >
      <div className="rounded-full bg-primary/10 p-2 shrink-0">
        <Sparkles size={16} className="text-primary" />
      </div>
      <div className="min-w-0 flex-1 text-sm">
        <p className="font-medium leading-tight">Unlock AI features</p>
        <p className="text-xs text-muted-foreground leading-tight">
          Sign in for TTS, chat, and sync.
        </p>
      </div>
      <Button
        size="sm"
        onClick={() => {
          void startSignInFlow();
        }}
      >
        <LogIn size={14} className="mr-1" />
        Sign in
      </Button>
      <button
        type="button"
        onClick={() => dismiss()}
        aria-label="Dismiss sign-in banner"
        className="absolute right-1 top-1 rounded p-1 text-muted-foreground hover:bg-muted"
      >
        <X size={12} />
      </button>
    </div>
  );
}
```

The `bottom-16` positions the card 4rem above the bottom edge — the `SyncStatusIndicator` lives at `bottom-4` (1rem), giving ~3rem of clearance. Adjust if visual review at Task 11 finds overlap.

- [ ] **Step 2: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/components/auth/SignInBanner.tsx
git commit -m "feat(main): add persistent SignInBanner component"
```

---

## Task 10: Refactor `LoginButton` to use `startSignInFlow`

**Files:**
- Modify: `apps/main/src/components/LoginButton.tsx`

This task removes the inline OAuth URL construction from `LoginButton.tsx` and replaces it with a call to `startSignInFlow()`. We do NOT yet remove the hydration `useEffect`s — that happens in Task 11 alongside the `__root.tsx` wiring, so the app stays functional after each commit.

- [ ] **Step 1: Replace the `login()` function body**

In `apps/main/src/components/LoginButton.tsx`, find this function (around lines 139–147):

```tsx
  async function login() {
    // Always generate fresh state+challenge on explicit login click
    const result = await getState();
    stateRef.current = result.state;
    codeChallengeRef.current = result.codeChallenge;
    await openUrl(
      `https://rishi.fidexa.org?login=true&state=${encodeURIComponent(stateRef.current!)}&code_challenge=${encodeURIComponent(codeChallengeRef.current!)}`
    );
  }
```

Replace with:

```tsx
  async function login() {
    await startSignInFlow();
  }
```

- [ ] **Step 2: Add the import**

At the top of the same file, with the other imports:

```tsx
import { startSignInFlow } from "@/modules/auth";
```

- [ ] **Step 3: Remove now-unused imports**

If `openUrl` is no longer referenced in this file, remove the `import { openUrl } from "@tauri-apps/plugin-opener";` line. Run:

```bash
cd apps/main && grep -n "openUrl" src/components/LoginButton.tsx
```

If `openUrl` only appears in `onProfileClicked` (the profile dropdown), keep the import. Otherwise remove it.

Similarly check `getState`:

```bash
cd apps/main && grep -n "getState" src/components/LoginButton.tsx
```

The `ensureState` helper inside the deep-link `useEffect` still uses `getState`, so the import must remain for now (it goes away in Task 11 when the effect is removed).

- [ ] **Step 4: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/LoginButton.tsx
git commit -m "refactor(main): LoginButton.login uses shared startSignInFlow"
```

---

## Task 11: Wire `useHydrateAuth`, `WelcomeModal`, and `SignInBanner` into `__root.tsx`; remove duplicated effects from `LoginButton`

**Files:**
- Modify: `apps/main/src/routes/__root.tsx`
- Modify: `apps/main/src/components/LoginButton.tsx`

This task completes the migration: the root owns auth bootstrap, and `LoginButton` becomes purely presentational. After this commit, the feature is end-to-end wired.

- [ ] **Step 1: Update `__root.tsx`**

In `apps/main/src/routes/__root.tsx`, modify the imports at the top to add:

```tsx
import { useHydrateAuth } from "@/hooks/useHydrateAuth";
import { WelcomeModal } from "@/components/auth/WelcomeModal";
import { SignInBanner } from "@/components/auth/SignInBanner";
```

Inside `RootComponent`, add `useHydrateAuth();` as the **first** line of the function body (before the `useEffect` that calls `initDesktopSync`). Then in the returned JSX, mount the two new components alongside the existing `SyncStatusIndicator`. The new component looks like:

```tsx
function RootComponent(): JSX.Element {
  useHydrateAuth();

  // Initialize desktop sync on app mount
  useEffect(() => {
    initDesktopSync();
    return () => {
      destroyDesktopSync();
    };
  }, []);

  const { isPending, error, data: _books, isError } = useQuery({
    queryKey: ["books"],
    queryFn: async () => {
      return await getBooks();
    },
    retry: 3,
    retryDelay: 1000,
  });

  if (isError)
    return (
      <div className="w-full h-screen place-items-center grid">
        {error.message}
      </div>
    );

  if (isPending)
    return (
      <div className="w-full h-screen place-items-center grid">
        <Loader />
      </div>
    );

  return (
    <>
      <Outlet />
      <WelcomeModal />
      <SignInBanner />
      <div className="fixed bottom-4 left-4 z-50 w-40">
        <SyncStatusIndicator />
      </div>
      <TanStackRouterDevtools />
    </>
  );
}
```

(Note the commented-out `GlobalFonts` and books-css block in the original file is removed in the snippet for clarity; preserve it if you want to keep the comments verbatim.)

- [ ] **Step 2: Strip the duplicated effects from `LoginButton.tsx`**

In `apps/main/src/components/LoginButton.tsx`, remove:

1. The `useEffect` that calls `getUserFromStore()` on mount (currently lines ~32-44).
2. The `useEffect` that calls `onOpenUrl(...)` and the entire OAuth callback retry loop (currently lines ~57-132).
3. The `stateRef`, `codeChallengeRef`, `ensureState`, `MAX_AUTH_RETRIES`, `BASE_RETRY_DELAY_MS`, and the `isLoading` state — all unused now.
4. The `isLoading` early return.

Also remove now-unused imports:

- `useEffect`, `useRef` from React (keep `useState` only if still used — after these removals it isn't, so drop it too)
- `getState`, `getUserFromStore`, `completeAuth`, `checkAuthStatus` from `@/generated` — keep only `signout`
- `onOpenUrl` from `@tauri-apps/plugin-deep-link`
- `useAtom` from `jotai` — keep `useAtomValue` for `isLoggedInAtom`; replace `const [user, setUser] = useAtom(userAtom)` with `const user = useAtomValue(userAtom)` since `LoginButton` no longer writes to `userAtom`.

After cleanup, the file should contain roughly:

```tsx
import { LogIn, LogOut } from "lucide-react";
import { Button } from "./ui/Button";
import { openUrl } from "@tauri-apps/plugin-opener";
import { signout } from "@/generated";
import { useAtomValue } from "jotai";
import { isLoggedInAtom, userAtom } from "./pdf/atoms/user";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/components/ui/dropdown-menu";
import { startSignInFlow } from "@/modules/auth";

export function LoginButton() {
  const user = useAtomValue(userAtom);
  const isLoggedIn = useAtomValue(isLoggedInAtom);

  async function onProfileClicked() {
    if (!user) return;
    await openUrl(`https://rishi.fidexa.org?profile=true`);
  }

  async function login() {
    await startSignInFlow();
  }

  async function logout() {
    await signout();
  }

  if (user && isLoggedIn) {
    return (
      <div className="flex gap-2">
        <DropdownMenu>
          <DropdownMenuTrigger>
            <Avatar>
              <AvatarImage src={user.imageUrl ?? ""} />
              <AvatarFallback>{user.firstName?.[0]}</AvatarFallback>
            </Avatar>
          </DropdownMenuTrigger>
          <DropdownMenuContent>
            <DropdownMenuItem onClick={onProfileClicked}>
              Profile
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <Button
          variant="ghost"
          className="cursor-pointer"
          startIcon={<LogOut size={20} />}
          onClick={logout}
        >
          Logout
        </Button>
      </div>
    );
  }
  return (
    <Button
      variant="ghost"
      className="cursor-pointer"
      startIcon={<LogIn size={20} />}
      onClick={login}
    >
      Login
    </Button>
  );
}
```

> Note: previously `LoginButton` cleared `userAtom` on logout via `setUser(null)`. After this refactor, that line is gone. Either (a) make `signout()` itself update `userAtom` from elsewhere, or (b) re-introduce a single `setUser(null)` call in `logout()` using `useSetAtom(userAtom)`. **Use option (b)** — it's the smallest change and matches existing behavior. Final `logout`:
>
> ```tsx
> const setUser = useSetAtom(userAtom);
> async function logout() {
>   setUser(null);
>   await signout();
> }
> ```
>
> And add `useSetAtom` to the jotai import.

- [ ] **Step 3: Type-check**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: no new errors. Any unused-variable warnings should disappear.

- [ ] **Step 4: Manual smoke test**

Start the app and verify:

```bash
cd apps/main && bun run dev
```

In a separate terminal, launch the Tauri shell as you normally would (or `npm run tauri dev` if the project uses that). Verify the following manually:

1. **Cold start, signed out, no `localStorage` flag** (open the dev console and run `localStorage.removeItem("rishi:welcome-seen"); location.reload()`):
   - The welcome modal appears after the books query resolves.
   - "Maybe later" closes the modal; the banner does NOT appear immediately (session-suppressed).
   - Reload the app: the banner now appears at bottom-left, just above the sync indicator.
2. **Cold start, signed out, banner visible:**
   - Click the banner X; it disappears for the rest of the session. Reload: it's back.
   - Click the banner "Sign in"; the OAuth URL opens in your browser.
3. **Cold start, signed in:**
   - Neither modal nor banner appears.
4. **Click any premium feature button (TTS play / chat) while signed out:**
   - The `PremiumFeatureDialog` appears with feature-specific copy (TTS title for play, chat title for chat icon).
   - "Sign in" closes the dialog and opens OAuth.

If anything misbehaves, fix and recommit before proceeding.

- [ ] **Step 5: Final commit**

```bash
git add apps/main/src/routes/__root.tsx \
        apps/main/src/components/LoginButton.tsx
git commit -m "feat(main): wire auth promos at root; LoginButton becomes presentational"
```

---

## Task 12: Run the full test suite

- [ ] **Step 1: Run unit tests**

```bash
cd apps/main && npx vitest run
```

Expected: all new tests pass; no pre-existing tests regress. The browser-only test files are excluded by `vitest.config.ts`.

- [ ] **Step 2: Lint**

```bash
cd apps/main && bun run lint
```

Expected: no new errors in any file added or modified by this plan.

- [ ] **Step 3: If any failures appear, fix and recommit**

For each failure, investigate root cause (do not silence). Fix in a follow-up commit:

```bash
git add <files>
git commit -m "fix(main): <specific fix>"
```

---

## Self-Review Notes

**Spec coverage check:**
- Welcome modal → Task 8 + Task 11 (mounted) ✓
- Sign-in banner → Task 9 + Task 11 (mounted) ✓
- Feature-specific premium dialog → Task 5 (component) + Task 6 (hook) + Task 7 (call sites) ✓
- Shared OAuth launch path → Task 3 (`startSignInFlow`) used by Tasks 5, 8, 9, 10 ✓
- Persistent localStorage flag → Task 2 (`hydrateWelcomeSeenAtom`, `setWelcomeSeenAtom`) ✓
- Session banner-dismissed atom → Task 2 (`bannerDismissedAtom`, `dismissBannerAtom`) ✓
- Hydration gate → Task 2 (`authHydratedAtom`) + Task 4 (set in `finally`) ✓
- Deep-link callback handling → Task 4 (`useHydrateAuth`) ✓
- "Maybe later" suppresses banner for session → Task 2 (`dismissWelcomeAtom`) + Task 8 (handler) ✓
- Fail-closed localStorage error handling → Task 2 (`hydrateWelcomeSeenAtom` test + impl) ✓
- Snapshot test of registry → Task 1 ✓
- Atom truth tables → Task 2 ✓
- `useRequireAuth` gating logic test → **NOT included**; see Task 6 rationale (no testing infrastructure available for hooks; logic is trivial branching covered by atom tests + manual smoke).
- Component render tests for the three new UI components → **NOT included** as automated tests; covered by Task 11 manual smoke test, justified by the existing minimal test coverage in `apps/main` and the simplicity of these components (atoms drive visibility; handlers are 1-2 lines each).

**Type consistency:** `PremiumFeature` type and `PREMIUM_FEATURES` registry signature defined in Task 1 and consumed unchanged in Tasks 5, 6, 7. `startSignInFlow()` signature defined in Task 3 and called from Tasks 5, 8, 9, 10.

**Functional state at each commit:** Every task ends in a working app:
- Task 6 leaves type errors at call sites — Task 7 must follow before merge. The author should land Tasks 6+7 together if reviewing PR-by-PR.
- Tasks 4, 5, 8, 9 add code that isn't yet wired in; the app continues to work via the old `LoginButton` effects.
- Task 11 is the cutover; after it, the old hydration path is gone.

**Out of scope (acknowledged):** billing/tiers, mobile, web, toast system, e2e tests, component render tests for the three UI surfaces.
