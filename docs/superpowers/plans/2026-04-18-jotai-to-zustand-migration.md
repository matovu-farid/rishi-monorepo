# Jotai → Zustand Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all Jotai state management in `apps/main` with 4 domain-scoped Zustand stores, simplifying the event bus to a plain module, and moving async paragraph fetching to React Query.

**Architecture:** 4 Zustand stores (auth, epub, pdf, chat) replace ~80+ Jotai atoms. Each store colocates state + actions. The Jotai provider and devtools are removed. Module-level `customStore.get/set` calls become `useXxxStore.getState()`.

**Tech Stack:** Zustand 5, React Query (already present), TypeScript

---

### Task 1: Install Zustand and Create Auth Store

**Files:**
- Modify: `apps/main/package.json` (add zustand dependency)
- Create: `apps/main/src/stores/authStore.ts`

- [ ] **Step 1: Install zustand**

```bash
cd apps/main && bun add zustand
```

- [ ] **Step 2: Create the auth store**

Create `apps/main/src/stores/authStore.ts`:

```typescript
import { create } from "zustand";
import { devtools } from "zustand/middleware";
import type { User } from "@/generated";

const WELCOME_SEEN_KEY = "rishi:welcome-seen";

interface AuthState {
  user: User | null;
  signingIn: boolean;
  authHydrated: boolean;
  welcomeSeen: boolean;
  bannerDismissed: boolean;
  devMode: boolean;

  // Actions
  setUser: (user: User | null) => void;
  setSigningIn: (value: boolean) => void;
  setDevMode: (value: boolean) => void;
  hydrateAuth: () => void;
  dismissBanner: () => void;
  dismissWelcome: () => void;
  setWelcomeSeen: () => void;
  setAuthHydrated: (value: boolean) => void;
}

export const useAuthStore = create<AuthState>()(
  devtools(
    (set) => ({
      user: null,
      signingIn: false,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      devMode: false,

      setUser: (user) => set({ user }),
      setSigningIn: (value) => set({ signingIn: value }),
      setDevMode: (value) => set({ devMode: value }),
      setAuthHydrated: (value) => set({ authHydrated: value }),

      hydrateAuth: () => {
        try {
          const value = localStorage.getItem(WELCOME_SEEN_KEY);
          set({ welcomeSeen: value === "1" });
        } catch (err) {
          console.warn("[authStore] failed to read welcome-seen flag, fail-closing:", err);
          set({ welcomeSeen: true });
        }
      },

      dismissBanner: () => set({ bannerDismissed: true }),

      dismissWelcome: () => {
        set({ welcomeSeen: true, bannerDismissed: true });
        try {
          localStorage.setItem(WELCOME_SEEN_KEY, "1");
        } catch (err) {
          console.warn("[authStore] failed to persist welcome-seen flag:", err);
        }
      },

      setWelcomeSeen: () => {
        set({ welcomeSeen: true });
        try {
          localStorage.setItem(WELCOME_SEEN_KEY, "1");
        } catch (err) {
          console.warn("[authStore] failed to persist welcome-seen flag:", err);
        }
      },
    }),
    { name: "auth-store" }
  )
);
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/package.json apps/main/bun.lockb apps/main/src/stores/authStore.ts
git commit -m "feat: add zustand and create auth store"
```

---

### Task 2: Migrate Auth Consumers to useAuthStore

**Files:**
- Modify: `apps/main/src/hooks/useHydrateAuth.tsx`
- Modify: `apps/main/src/hooks/useRequireAuth.tsx`
- Modify: `apps/main/src/components/auth/WelcomeModal.tsx`
- Modify: `apps/main/src/components/auth/SignInBanner.tsx`
- Modify: `apps/main/src/components/auth/PremiumFeatureDialog.tsx`
- Modify: `apps/main/src/components/LoginButton.tsx`
- Modify: `apps/main/src/modules/auth.ts`

- [ ] **Step 1: Migrate `modules/auth.ts`**

Replace the Jotai store import and usage:

```typescript
// Replace these lines:
import { getDefaultStore } from "jotai";
import { signingInAtom } from "@/atoms/authPromo";

const store = getDefaultStore();

// With:
import { useAuthStore } from "@/stores/authStore";
```

Replace `store.set(signingInAtom, true)` with `useAuthStore.getState().setSigningIn(true)` (2 occurrences — one in the try block, one in the catch block of `startSignInFlow`).

- [ ] **Step 2: Migrate `hooks/useHydrateAuth.tsx`**

Replace imports:

```typescript
// Remove:
import { useSetAtom } from "jotai";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  hydrateWelcomeSeenAtom,
  signingInAtom,
  devModeAtom,
} from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace the hook body. Remove individual `useSetAtom` calls and replace with store actions:

```typescript
export function useHydrateAuth(): void {
  const { setUser, setAuthHydrated, hydrateAuth, setSigningIn, setDevMode } = useAuthStore();

  useEffect(() => {
    hydrateAuth();

    void (async () => {
      try {
        const dev = await isDev();
        setDevMode(dev);
      } catch { /* ignore */ }
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
  }, []);

  // Deep-link callback listener stays the same, just use store actions
  useEffect(() => {
    const unlisten = onOpenUrl(async (urls) => {
      void debugLog("global", "onOpenUrl_fired", { urlCount: urls.length, urls: urls.map(u => u.slice(0, 100)) });

      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          console.error("[useHydrateAuth] malformed deep link URL:", url);
          void debugLog("unknown", "deeplink_malformed_url", { url: url.slice(0, 200) });
          toast.error("Sign-in failed: malformed callback URL");
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) {
          void debugLog("unknown", "deeplink_missing_state", { url: url.slice(0, 200) });
          toast.error("Sign-in failed: missing state parameter");
          continue;
        }

        void debugLog(callbackState, "deeplink_received", { url: url.slice(0, 200) });

        const expected = peekPendingOAuthState();
        void debugLog(callbackState, "deeplink_state_check", {
          hasPendingState: !!expected,
          pendingStateMatch: expected ? callbackState === expected.state : "n/a",
        });

        if (expected && callbackState !== expected.state) {
          console.error(
            "[useHydrateAuth] auth callback state mismatch — ignoring",
            { callbackState, expectedState: expected.state },
          );
          void debugLog(callbackState, "deeplink_state_mismatch", {
            expectedState: expected.state.slice(0, 8) + "...",
          });
          toast.error("Sign-in failed: state mismatch. Please try signing in again.");
          continue;
        }

        let lastError: unknown = null;
        for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
          try {
            void debugLog(callbackState, "complete_auth_attempt", { attempt, maxRetries: MAX_AUTH_RETRIES });
            const user = await completeAuth({ state: callbackState });
            void debugLog(callbackState, "complete_auth_success_ts", { userId: user.id, attempt });
            setUser(user);
            setSigningIn(false);
            clearPendingOAuthState();
            const greeting = user.firstName
              ? `Signed in as ${user.firstName}`
              : "Signed in successfully";
            toast.success(greeting);
            return;
          } catch (error) {
            lastError = error;
            const errMsg = String(error);
            console.error(
              `[useHydrateAuth] auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`,
              error,
            );
            void debugLog(callbackState, "complete_auth_attempt_failed", { attempt }, errMsg);

            if (
              errMsg.includes("already used") ||
              errMsg.includes("permanently failed") ||
              errMsg.includes("Max retries")
            ) {
              void debugLog(callbackState, "complete_auth_terminal_failure", { attempt }, errMsg);
              setSigningIn(false);
              clearPendingOAuthState();
              break;
            }

            if (attempt < MAX_AUTH_RETRIES) {
              const is409 = errMsg.includes("409") || errMsg.includes("in progress");
              const delay = is409
                ? BASE_RETRY_DELAY_MS * 3
                : BASE_RETRY_DELAY_MS * attempt;

              try {
                const status = await checkAuthStatus({ state: callbackState });
                console.log("[useHydrateAuth] auth flow status:", status);
                void debugLog(callbackState, "auth_status_check", status);
                if (status.status === "not_found" || status.status === "completed") {
                  clearPendingOAuthState();
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
        setSigningIn(false);
        void debugLog(callbackState, "all_auth_attempts_failed", null, describeAuthError(lastError));
        toast.error(`Sign-in failed: ${describeAuthError(lastError)}`);
      }
    });

    return () => {
      void unlisten.then((fn) => fn());
    };
  }, []);
}
```

- [ ] **Step 3: Migrate `hooks/useRequireAuth.tsx`**

```typescript
// Remove:
import { useAtomValue } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";
import { devModeAtom } from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace the atom reads inside the hook:

```typescript
export function useRequireAuth() {
  const isLoggedIn = useAuthStore((s) => s.user !== null);
  const isDevMode = useAuthStore((s) => s.devMode);
  // ... rest stays the same
```

- [ ] **Step 4: Migrate `components/auth/WelcomeModal.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import {
  showWelcomeModalAtom,
  setWelcomeSeenAtom,
  dismissWelcomeAtom,
  signingInAtom,
} from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace the hook calls inside the component:

```typescript
export function WelcomeModal(): React.JSX.Element {
  const open = useAuthStore(
    (s) => s.authHydrated && s.user === null && !s.welcomeSeen
  );
  const setWelcomeSeen = useAuthStore((s) => s.setWelcomeSeen);
  const dismissWelcome = useAuthStore((s) => s.dismissWelcome);
  const signingIn = useAuthStore((s) => s.signingIn);
  // ... rest stays the same
```

- [ ] **Step 5: Migrate `components/auth/SignInBanner.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import {
  showSignInBannerAtom,
  dismissBannerAtom,
  signingInAtom,
} from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace hook calls:

```typescript
export function SignInBanner(): React.JSX.Element | null {
  const visible = useAuthStore(
    (s) => s.authHydrated && s.user === null && s.welcomeSeen && !s.bannerDismissed
  );
  const dismiss = useAuthStore((s) => s.dismissBanner);
  const signingIn = useAuthStore((s) => s.signingIn);
  // ... rest stays the same
```

- [ ] **Step 6: Migrate `components/auth/PremiumFeatureDialog.tsx`**

```typescript
// Remove:
import { useAtomValue } from "jotai";
import { signingInAtom } from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace:

```typescript
const signingIn = useAuthStore((s) => s.signingIn);
```

- [ ] **Step 7: Migrate `components/LoginButton.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import { isLoggedInAtom, userAtom } from "./pdf/atoms/user";
import { signingInAtom } from "@/atoms/authPromo";

// Add:
import { useAuthStore } from "@/stores/authStore";
```

Replace hook calls:

```typescript
export function LoginButton() {
  const user = useAuthStore((s) => s.user);
  const isLoggedIn = useAuthStore((s) => s.user !== null);
  const setUser = useAuthStore((s) => s.setUser);
  const signingIn = useAuthStore((s) => s.signingIn);
  // ... rest stays the same
```

- [ ] **Step 8: Verify the app compiles**

```bash
cd apps/main && bun run build
```

Expected: Build succeeds with no errors referencing `authPromo`, `userAtom`, or `isLoggedInAtom`.

- [ ] **Step 9: Commit**

```bash
git add -A apps/main/src/hooks/useHydrateAuth.tsx apps/main/src/hooks/useRequireAuth.tsx apps/main/src/components/auth/WelcomeModal.tsx apps/main/src/components/auth/SignInBanner.tsx apps/main/src/components/auth/PremiumFeatureDialog.tsx apps/main/src/components/LoginButton.tsx apps/main/src/modules/auth.ts
git commit -m "refactor: migrate auth consumers from Jotai atoms to useAuthStore"
```

---

### Task 3: Create Chat Store and Migrate Consumers

**Files:**
- Create: `apps/main/src/stores/chatStore.ts`
- Modify: `apps/main/src/components/TTSControls.tsx`
- Modify: `apps/main/src/components/BackButton.tsx`

- [ ] **Step 1: Create the chat store**

Create `apps/main/src/stores/chatStore.ts`:

```typescript
import { create } from "zustand";
import { devtools } from "zustand/middleware";
import type { RealtimeSession } from "@openai/agents/realtime";
import { startRealtime } from "@/modules/realtime";

interface ChatState {
  isChatting: boolean;
  realtimeSession: RealtimeSession | null;

  setIsChatting: (value: boolean | ((prev: boolean) => boolean)) => void;
  startChat: (bookId: number) => void;
  stopConversation: () => void;
}

export const useChatStore = create<ChatState>()(
  devtools(
    (set, get) => ({
      isChatting: false,
      realtimeSession: null,

      setIsChatting: (value) =>
        set((state) => ({
          isChatting: typeof value === "function" ? value(state.isChatting) : value,
        })),

      startChat: (bookId: number) => {
        void startRealtime(bookId).then((session) => {
          set({ realtimeSession: session });
        });
      },

      stopConversation: () => {
        const { realtimeSession } = get();
        if (realtimeSession) {
          realtimeSession.close();
          set({ realtimeSession: null, isChatting: false });
        }
      },
    }),
    { name: "chat-store" }
  )
);
```

- [ ] **Step 2: Migrate `components/TTSControls.tsx`**

```typescript
// Remove:
import { atom, useAtom, useAtomValue, useSetAtom } from "jotai";
import { isChattingAtom, stopConversationAtom } from "@/stores/chat_atoms";

// Add:
import { useChatStore } from "@/stores/chatStore";
```

Replace hook calls (keep the local `playerAtom` — it's component-local and trivial, just inline it):

```typescript
// Remove the playerAtom definition:
// const playerAtom = atom(player);
// playerAtom.debugLabel = "playerAtom";

// Inside TTSControls, replace:
// const player = useAtomValue(playerAtom);
// const stopConversation = useSetAtom(stopConversationAtom);
// const [isChatting, setIsChatting] = useAtom(isChattingAtom);

// With:
const stopConversation = useChatStore((s) => s.stopConversation);
const isChatting = useChatStore((s) => s.isChatting);
const setIsChatting = useChatStore((s) => s.setIsChatting);
// player is already a module-level import, just use it directly (remove playerAtom/useAtomValue):
// const player = useAtomValue(playerAtom);  →  already imported as `import player from "@/models/Player";`
```

Note: The `player` is already imported at the top of the file as `import player from "@/models/Player"`. The `playerAtom` wrapping it in a Jotai atom was unnecessary. Just use `player` directly.

- [ ] **Step 3: Migrate `components/BackButton.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import { stopConversationAtom } from "@/stores/chat_atoms";

// Add:
import { useChatStore } from "@/stores/chatStore";
```

Replace:

```typescript
export function BackButton() {
  const theme = useEpubStore((s) => s.theme); // (will be migrated in Task 5, for now keep the jotai import for themeAtom)
  const stopConversation = useChatStore((s) => s.stopConversation);
  // ... rest stays the same
```

**Important:** BackButton also uses `themeAtom` from epub_atoms. For now, keep that Jotai import — it will be migrated in Task 5. Only migrate the chat-related atom here.

So the actual imports for BackButton after this step:

```typescript
import { useAtomValue } from "jotai";
import { themeAtom } from "@/stores/epub_atoms";
import { useChatStore } from "@/stores/chatStore";
```

And replace `const stopConversation = useSetAtom(stopConversationAtom)` with `const stopConversation = useChatStore((s) => s.stopConversation)`.

- [ ] **Step 4: Verify the app compiles**

```bash
cd apps/main && bun run build
```

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/stores/chatStore.ts apps/main/src/components/TTSControls.tsx apps/main/src/components/BackButton.tsx
git commit -m "refactor: migrate chat state from Jotai to useChatStore"
```

---

### Task 4: Create Epub Store and Migrate Consumers

**Files:**
- Create: `apps/main/src/stores/epubStore.ts`
- Modify: `apps/main/src/components/epub.tsx`
- Modify: `apps/main/src/components/mobi/MobiView.tsx`
- Modify: `apps/main/src/components/djvu/DjvuView.tsx`
- Modify: `apps/main/src/components/BackButton.tsx` (finish themeAtom migration)

- [ ] **Step 1: Create the epub store**

Create `apps/main/src/stores/epubStore.ts`:

```typescript
import { create } from "zustand";
import { devtools } from "zustand/middleware";
import type Rendition from "epubjs/types/rendition";
import { ThemeType } from "@/themes/common";

interface EpubState {
  rendition: Rendition | null;
  paragraphRendition: Rendition | null;
  bookId: string;
  currentEpubLocation: string;
  theme: ThemeType;
  renditionCount: number;

  // Actions
  setRendition: (rendition: Rendition | null) => void;
  setParagraphRendition: (rendition: Rendition | null) => void;
  setBookId: (id: string) => void;
  setCurrentEpubLocation: (location: string) => void;
  setTheme: (theme: ThemeType) => void;
  incrementRenditionCount: () => void;
  reset: () => void;
}

export const useEpubStore = create<EpubState>()(
  devtools(
    (set) => ({
      rendition: null,
      paragraphRendition: null,
      bookId: "",
      currentEpubLocation: "",
      theme: ThemeType.White,
      renditionCount: 0,

      setRendition: (rendition) => set({ rendition }),
      setParagraphRendition: (paragraphRendition) => set({ paragraphRendition }),
      setBookId: (bookId) => set({ bookId }),
      setCurrentEpubLocation: (currentEpubLocation) => set({ currentEpubLocation }),
      setTheme: (theme) => set({ theme }),
      incrementRenditionCount: () =>
        set((state) => ({ renditionCount: state.renditionCount + 1 })),
      reset: () =>
        set({
          rendition: null,
          paragraphRendition: null,
          bookId: "",
          currentEpubLocation: "",
          renditionCount: 0,
        }),
    }),
    { name: "epub-store" }
  )
);
```

- [ ] **Step 2: Set up epub side effects**

The old `epub_atoms.ts` had several `observe()` calls that need to be converted. Create a side-effect initializer that uses `useEpubStore.subscribe()`.

Add to the bottom of `apps/main/src/stores/epubStore.ts`:

```typescript
import {
  getAllParagraphsForBook,
  getCurrentViewParagraphs,
  getNextViewParagraphs,
  getPreviousViewParagraphs,
} from "@/epubwrapper";
import { eventBus, EventBusEvent } from "@/utils/bus";
import { processEpubJob } from "@/modules/process_epub";
import { hasSavedEpubData } from "@/generated";
import type { ParagraphWithIndex } from "@/models/player_control";

// Side effect: when paragraphRendition + bookId are set, process all paragraphs
useEpubStore.subscribe(
  (state) => ({ paragraphRendition: state.paragraphRendition, bookId: state.bookId }),
  (current, previous) => {
    const { paragraphRendition, bookId } = current;
    if (paragraphRendition && bookId && (
      paragraphRendition !== previous.paragraphRendition || bookId !== previous.bookId
    )) {
      void hasSavedEpubData({ bookId: Number(bookId) }).then((hasSaved) => {
        if (!hasSaved) {
          console.log(">>> GETTING PARAGRAPHS");
          void getAllParagraphsForBook(paragraphRendition, bookId).then((paragraphs) => {
            console.log(">>> PARAGRAPHS", paragraphs);
            void processEpubJob(Number(bookId), paragraphs);
          });
        }
      });
    }
  },
  { equalityFn: (a, b) => a.paragraphRendition === b.paragraphRendition && a.bookId === b.bookId }
);

// Side effect: when rendition + location change, publish current/next/prev paragraphs
useEpubStore.subscribe(
  (state) => ({ rendition: state.rendition, location: state.currentEpubLocation }),
  (current) => {
    const { rendition, location } = current;
    if (!rendition) return;

    // Current view paragraphs
    const paragraphs = getCurrentViewParagraphs(rendition).map((p) => ({
      text: p.text,
      index: p.cfiRange,
    }));
    eventBus.publish(EventBusEvent.NEW_PARAGRAPHS_AVAILABLE, paragraphs);

    // Next view paragraphs
    void getNextViewParagraphs(rendition).then((nextParagraphs) => {
      const mapped = nextParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.NEXT_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });

    // Previous view paragraphs
    void getPreviousViewParagraphs(rendition).then((prevParagraphs) => {
      const mapped = prevParagraphs.map((p) => ({
        text: p.text,
        index: p.cfiRange,
      }));
      eventBus.publish(EventBusEvent.PREVIOUS_VIEW_PARAGRAPHS_AVAILABLE, mapped);
    });
  },
  { equalityFn: (a, b) => a.rendition === b.rendition && a.location === b.location }
);

// Side effect: when isChatting + bookId change, start realtime session
// (moved from chat_atoms.ts — needs bookId from epub store)
import { useChatStore } from "./chatStore";

useChatStore.subscribe(
  (state) => state.isChatting,
  (isChatting) => {
    const bookId = useEpubStore.getState().bookId;
    if (isChatting && bookId) {
      useChatStore.getState().startChat(Number(bookId));
    }
  }
);
```

**Note:** Zustand's `subscribe` with a selector requires the `subscribeWithSelector` middleware. Update the store creation:

```typescript
import { devtools, subscribeWithSelector } from "zustand/middleware";

export const useEpubStore = create<EpubState>()(
  devtools(
    subscribeWithSelector(
      (set) => ({
        // ... same as above
      })
    ),
    { name: "epub-store" }
  )
);
```

Also add `subscribeWithSelector` to `chatStore.ts`:

```typescript
import { devtools, subscribeWithSelector } from "zustand/middleware";

export const useChatStore = create<ChatState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        // ... same as before
      })
    ),
    { name: "chat-store" }
  )
);
```

- [ ] **Step 3: Migrate `components/epub.tsx`**

Replace Jotai imports and hooks:

```typescript
// Remove:
import { useAtom, useAtomValue, useSetAtom } from "jotai";
import {
  bookIdAtom,
  currentEpubLocationAtom,
  getEpubCurrentViewParagraphsAtom,
  paragraphRenditionAtom,
  renditionAtom,
  themeAtom,
} from "@/stores/epub_atoms";
import { eventBusLogsAtom } from "@/utils/bus";
import { customStore } from "@/stores/jotai";

// Add:
import { useEpubStore } from "@/stores/epubStore";
```

Replace hook calls inside `EpubView`:

```typescript
const theme = useEpubStore((s) => s.theme);
const setTheme = useEpubStore((s) => s.setTheme);
const rendition = useEpubStore((s) => s.rendition);
const setRendition = useEpubStore((s) => s.setRendition);
const setBookId = useEpubStore((s) => s.setBookId);
const setCurrentEpubLocation = useEpubStore((s) => s.setCurrentEpubLocation);
const setParagraphRendition = useEpubStore((s) => s.setParagraphRendition);
```

Remove `useAtomValue(eventBusLogsAtom)` — this was a force-rerender hack. It is no longer needed since the epub store subscriptions handle paragraph publishing.

Replace the `clearAllHighlights` function — it used `customStore.get(getEpubCurrentViewParagraphsAtom)`. Instead, get current paragraphs directly from the rendition:

```typescript
async function clearAllHighlights() {
  if (!rendition) return;
  const paragraphs = getCurrentViewParagraphs(rendition);
  return Promise.all(
    paragraphs.map((paragraph) => removeHighlight(rendition, paragraph.cfiRange))
  );
}
```

Add the import for `getCurrentViewParagraphs`:

```typescript
import { highlightRange, removeHighlight, getCurrentViewParagraphs } from "@/epubwrapper";
```

Replace `const [theme, setTheme] = useAtom(themeAtom)` and `const [rendition, setRendition] = useAtom(renditionAtom)` with the individual zustand selectors above.

- [ ] **Step 4: Migrate `components/BackButton.tsx`** (finish epub migration)

```typescript
// Remove:
import { useAtomValue } from "jotai";
import { themeAtom } from "@/stores/epub_atoms";

// Add:
import { useEpubStore } from "@/stores/epubStore";
```

Replace:

```typescript
const theme = useEpubStore((s) => s.theme);
```

- [ ] **Step 5: Migrate `components/mobi/MobiView.tsx`**

Replace Jotai imports:

```typescript
// Remove:
import { useAtom } from "jotai";
import { useSetAtom } from "jotai";
import { bookIdAtom, themeAtom } from "@/stores/epub_atoms";

// Add:
import { useEpubStore } from "@/stores/epubStore";
```

Replace hook calls — find and replace patterns like:
- `useSetAtom(bookIdAtom)` → `useEpubStore((s) => s.setBookId)`
- `useAtom(themeAtom)` → `const theme = useEpubStore((s) => s.theme)` and `const setTheme = useEpubStore((s) => s.setTheme)`

- [ ] **Step 6: Migrate `components/djvu/DjvuView.tsx`**

Same pattern as MobiView:

```typescript
// Remove:
import { useSetAtom } from "jotai";
import { bookIdAtom } from "@/stores/epub_atoms";

// Add:
import { useEpubStore } from "@/stores/epubStore";
```

Replace `useSetAtom(bookIdAtom)` → `useEpubStore((s) => s.setBookId)`.

- [ ] **Step 7: Verify the app compiles**

```bash
cd apps/main && bun run build
```

- [ ] **Step 8: Commit**

```bash
git add apps/main/src/stores/epubStore.ts apps/main/src/stores/chatStore.ts apps/main/src/components/epub.tsx apps/main/src/components/BackButton.tsx apps/main/src/components/mobi/MobiView.tsx apps/main/src/components/djvu/DjvuView.tsx
git commit -m "refactor: migrate epub and reader state from Jotai to useEpubStore"
```

---

### Task 5: Create PDF Store and Migrate Consumers

**Files:**
- Create: `apps/main/src/stores/pdfStore.ts`
- Modify: `apps/main/src/components/pdf/components/pdf.tsx`
- Modify: `apps/main/src/components/pdf/components/pdf-page.tsx`
- Modify: `apps/main/src/components/pdf/components/thumbnail-sidebar.tsx`
- Modify: `apps/main/src/components/pdf/components/text-extractor.tsx`
- Modify: `apps/main/src/components/pdf/components/background-page.tsx`
- Modify: `apps/main/src/components/pdf/hooks/usePdfNavigation.tsx`
- Modify: `apps/main/src/components/pdf/hooks/useScrolling.tsx`
- Modify: `apps/main/src/components/pdf/hooks/useCurrentPageNumber.tsx`
- Modify: `apps/main/src/components/pdf/hooks/useSetupMenu.tsx`
- Modify: `apps/main/src/components/pdf/hooks/useVirualization.tsx`
- Modify: `apps/main/src/components/pdf/hooks/useUpdateCoverIMage.tsx`
- Modify: `apps/main/src/components/pdf/subscriptions/bus.ts`
- Modify: `apps/main/src/components/FileComponent.tsx`
- Modify: `apps/main/src/routes/books.$id.lazy.tsx`
- Modify: `apps/main/src/modules/updater.ts`

- [ ] **Step 1: Create the PDF store**

Create `apps/main/src/stores/pdfStore.ts`:

```typescript
import { create } from "zustand";
import { devtools, subscribeWithSelector } from "zustand/middleware";
import type { TextContent } from "react-pdf";
import type { PDFDocumentProxy } from "pdfjs-dist";
import type { ParagraphWithIndex } from "@/models/player_control";
import type { Book } from "@/generated";

export type Paragraph = ParagraphWithIndex & {
  dimensions: {
    top: number;
    bottom: number;
  };
};

export enum BookNavigationState {
  Idle,
  Navigating,
  Navigated,
}

interface PdfState {
  // State
  pageNumber: number;
  scrollPageNumber: number;
  pageCount: number;
  isDualPage: boolean;
  thumbnailSidebarOpen: boolean;
  pdfDocumentProxy: PDFDocumentProxy | null;
  pageNumberToPageData: Record<number, TextContent>;
  pdfsRendered: Record<string, boolean>;
  books: number[];
  book: Book | null;
  currentParagraph: ParagraphWithIndex;
  currentViewParagraphs: Paragraph[];
  nextViewParagraphs: Paragraph[];
  previousViewParagraphs: Paragraph[];
  highlightedParagraphIndex: string;
  isHighlighting: boolean;
  isTextGot: boolean;
  virtualizer: any | null;
  bookNavigationState: BookNavigationState;
  backgroundPage: number;
  isRenderedPageState: Record<number, boolean>;
  hasNavigatedToPage: boolean;
  isLookingForNextParagraph: boolean;

  // Actions
  setPageNumber: (n: number) => void;
  setScrollPageNumber: (n: number) => void;
  nextPage: () => void;
  previousPage: () => void;
  changePage: (offset: number) => void;
  setDualPage: (value: boolean) => void;
  setThumbnailSidebarOpen: (value: boolean | ((prev: boolean) => boolean)) => void;
  setPdfDocumentProxy: (proxy: PDFDocumentProxy | null) => void;
  setPageData: (pageNumber: number, data: TextContent) => void;
  setBook: (book: Book | null) => void;
  setPageCount: (n: number) => void;
  setCurrentParagraph: (p: ParagraphWithIndex) => void;
  setCurrentViewParagraphs: (p: Paragraph[]) => void;
  setNextViewParagraphs: (p: Paragraph[]) => void;
  setPreviousViewParagraphs: (p: Paragraph[]) => void;
  setHighlightedParagraphIndex: (index: string) => void;
  setIsHighlighting: (value: boolean) => void;
  setIsTextGot: (value: boolean) => void;
  setVirtualizer: (v: any) => void;
  setBookNavigationState: (state: BookNavigationState) => void;
  setBackgroundPage: (value: number | ((prev: number) => number)) => void;
  setHasNavigatedToPage: (value: boolean) => void;
  setIsLookingForNextParagraph: (value: boolean) => void;
  setIsPdfRendered: (bookId: string, isRendered: boolean) => void;
  isPdfRendered: (bookId: string) => boolean;
  resetParagraphState: () => void;

  // PDF controller actions
  addBook: (id: number) => void;
  removeBook: (id: number) => void;
  setAllBooks: (ids: number[]) => void;
}

export const usePdfStore = create<PdfState>()(
  devtools(
    subscribeWithSelector(
      (set, get) => ({
        // Initial state
        pageNumber: 0,
        scrollPageNumber: 0,
        pageCount: 0,
        isDualPage: false,
        thumbnailSidebarOpen: false,
        pdfDocumentProxy: null,
        pageNumberToPageData: {},
        pdfsRendered: {},
        books: [],
        book: null,
        currentParagraph: { index: "", text: "" },
        currentViewParagraphs: [],
        nextViewParagraphs: [],
        previousViewParagraphs: [],
        highlightedParagraphIndex: "",
        isHighlighting: false,
        isTextGot: false,
        virtualizer: null,
        bookNavigationState: BookNavigationState.Idle,
        backgroundPage: 1,
        isRenderedPageState: {},
        hasNavigatedToPage: false,
        isLookingForNextParagraph: false,

        // Actions
        setPageNumber: (n) => {
          const state = get();
          if (state.bookNavigationState === BookNavigationState.Navigating) {
            return;
          }
          if (state.bookNavigationState === BookNavigationState.Idle) {
            set({ bookNavigationState: BookNavigationState.Navigating });
          }
          set({ pageNumber: n });
        },

        setScrollPageNumber: (n) => set({ scrollPageNumber: n }),

        nextPage: () => {
          const state = get();
          const increment = state.isDualPage ? 2 : 1;
          state.changePage(increment);
        },

        previousPage: () => {
          const state = get();
          const increment = state.isDualPage ? 2 : 1;
          state.changePage(-increment);
        },

        changePage: (offset) => {
          const state = get();
          set({ isRenderedPageState: {} });
          const newPageNumber = state.pageNumber + offset;
          if (newPageNumber >= 1 && newPageNumber <= state.pageCount) {
            // Use setPageNumber which has navigation state logic
            get().setPageNumber(newPageNumber);
          }
        },

        setDualPage: (value) => set({ isDualPage: value }),

        setThumbnailSidebarOpen: (value) =>
          set((state) => ({
            thumbnailSidebarOpen:
              typeof value === "function"
                ? value(state.thumbnailSidebarOpen)
                : value,
          })),

        setPdfDocumentProxy: (proxy) => set({ pdfDocumentProxy: proxy }),

        setPageData: (pageNumber, data) =>
          set((state) => ({
            pageNumberToPageData: {
              ...state.pageNumberToPageData,
              [pageNumber]: data,
            },
          })),

        setBook: (book) => set({ book }),
        setPageCount: (n) => set({ pageCount: n }),
        setCurrentParagraph: (p) => set({ currentParagraph: p }),
        setCurrentViewParagraphs: (p) => set({ currentViewParagraphs: p }),
        setNextViewParagraphs: (p) => set({ nextViewParagraphs: p }),
        setPreviousViewParagraphs: (p) => set({ previousViewParagraphs: p }),
        setHighlightedParagraphIndex: (index) =>
          set({ highlightedParagraphIndex: index }),
        setIsHighlighting: (value) => set({ isHighlighting: value }),
        setIsTextGot: (value) => set({ isTextGot: value }),
        setVirtualizer: (v) => set({ virtualizer: v }),
        setBookNavigationState: (state) => set({ bookNavigationState: state }),
        setBackgroundPage: (value) =>
          set((state) => ({
            backgroundPage:
              typeof value === "function"
                ? value(state.backgroundPage)
                : value,
          })),
        setHasNavigatedToPage: (value) => set({ hasNavigatedToPage: value }),
        setIsLookingForNextParagraph: (value) =>
          set({ isLookingForNextParagraph: value }),

        setIsPdfRendered: (bookId, isRendered) =>
          set((state) => ({
            pdfsRendered: { ...state.pdfsRendered, [bookId]: isRendered },
          })),

        isPdfRendered: (bookId) => {
          return get().pdfsRendered[bookId] ?? false;
        },

        resetParagraphState: () =>
          set({
            isDualPage: false,
            pageCount: 0,
            highlightedParagraphIndex: "",
            isHighlighting: false,
            isRenderedPageState: {},
          }),

        // PDF controller actions
        addBook: (id) => {
          const state = get();
          if (!state.books.includes(id)) {
            set({
              books: [...state.books, id],
              pdfsRendered: { ...state.pdfsRendered, [id]: false },
            });
          }
        },

        removeBook: (id) => {
          const state = get();
          const { [id]: _, ...rest } = state.pdfsRendered;
          set({
            books: state.books.filter((b) => b !== id),
            pdfsRendered: rest,
          });
        },

        setAllBooks: (ids) => {
          const state = get();
          const newRendered: Record<string, boolean> = {};
          for (const id of ids) {
            newRendered[id] = state.pdfsRendered[id] ?? false;
          }
          set({ books: ids, pdfsRendered: newRendered });
        },
      })
    ),
    { name: "pdf-store" }
  )
);

// Side effect: sync scroll page number → page number
usePdfStore.subscribe(
  (state) => state.scrollPageNumber,
  (scrollPageNumber) => {
    const store = usePdfStore.getState();
    // Only update if not in a programmatic navigation
    if (store.bookNavigationState !== BookNavigationState.Navigating) {
      usePdfStore.setState({ pageNumber: scrollPageNumber });
    }
  }
);
```

- [ ] **Step 2: Migrate `components/pdf/subscriptions/bus.ts`**

```typescript
import { eventBus, EventBusEvent } from "@/utils/bus";
import { nextPage, previousPage } from "../utils/pageControls";
import { usePdfStore } from "@/stores/pdfStore";

eventBus.subscribe(EventBusEvent.NEXT_PAGE_PARAGRAPHS_EMPTIED, async () => {
  nextPage();
});

eventBus.subscribe(
  EventBusEvent.PREVIOUS_PAGE_PARAGRAPHS_EMPTIED,
  async () => {
    previousPage();
  }
);

eventBus.subscribe(EventBusEvent.PLAYING_AUDIO, async (paragraph) => {
  usePdfStore.getState().setIsHighlighting(true);
  usePdfStore.getState().setHighlightedParagraphIndex(paragraph.index);
});
```

- [ ] **Step 3: Migrate `components/pdf/components/pdf.tsx`**

```typescript
// Remove:
import { useAtom, useAtomValue, useSetAtom } from "jotai";
import {
  hasNavigatedToPageAtom,
  pageCountAtom,
  resetParaphStateAtom,
  setPageNumberAtom,
  thumbnailSidebarOpenAtom,
  pdfDocumentProxyAtom,
  bookNavigationStateAtom,
  BookNavigationState,
} from "@components/pdf/atoms/paragraph-atoms";
import { eventBusLogsAtom } from "@/utils/bus";

// Add:
import { usePdfStore, BookNavigationState } from "@/stores/pdfStore";
```

Replace hook calls:

```typescript
const thumbOpen = usePdfStore((s) => s.thumbnailSidebarOpen);
const setThumbOpen = usePdfStore((s) => s.setThumbnailSidebarOpen);
const setPdfDocProxy = usePdfStore((s) => s.setPdfDocumentProxy);
const setBookNavState = usePdfStore((s) => s.setBookNavigationState);
const setPageNumber = usePdfStore((s) => s.setPageNumber);
const resetParaphState = usePdfStore((s) => s.resetParagraphState);
const setPageCount = usePdfStore((s) => s.setPageCount);
const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage);
```

Remove `useAtomValue(eventBusLogsAtom)`.

- [ ] **Step 4: Migrate `components/pdf/components/pdf-page.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import {
  highlightedParagraphAtom,
  isHighlightingAtom,
  pageNumberAtom,
  isPdfRenderedAtom,
  getCurrentViewParagraphsAtom,
  getNextViewParagraphsAtom,
  getPreviousViewParagraphsAtom,
  isTextGotAtom,
  setPageNumberToPageDataAtom,
} from "@components/pdf/atoms/paragraph-atoms";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace hook calls:

```typescript
const isHighlighting = usePdfStore((s) => s.isHighlighting);
const currentPage = usePdfStore((s) => s.pageNumber);
const setCurrentViewParagraphs = usePdfStore((s) => s.setCurrentViewParagraphs);
const setNextViewParagraphs = usePdfStore((s) => s.setNextViewParagraphs);
const setPreviousViewParagraphs = usePdfStore((s) => s.setPreviousViewParagraphs);
const setIsPdfRendered = usePdfStore((s) => s.setIsPdfRendered);
const setPageData = usePdfStore((s) => s.setPageData);
const setIsTextGot = usePdfStore((s) => s.setIsTextGot);

// For the derived highlightedParagraph:
const highlightedParagraphIndex = usePdfStore((s) => s.highlightedParagraphIndex);
const currentViewParagraphs = usePdfStore((s) => s.currentViewParagraphs);
const highlightedParagraph = currentViewParagraphs.find(
  (p) => p.index === highlightedParagraphIndex
);
```

Replace `setPageNumberToPageData` call:

```typescript
// Before:
onGetTextSuccess={(data) => {
  setPageNumberToPageData({ pageNumber, pageData: data });
}}

// After:
onGetTextSuccess={(data) => {
  setPageData(pageNumber, data);
}}
```

Replace `setIsCanvasRendered(bookId, true)`:

```typescript
// Before: setIsCanvasRendered(bookId, true)
// After: setIsPdfRendered(bookId, true)
```

- [ ] **Step 5: Migrate `components/pdf/components/thumbnail-sidebar.tsx`**

```typescript
// Remove:
import { useAtomValue } from "jotai";
import {
  pageCountAtom,
  pageNumberAtom,
  pdfDocumentProxyAtom,
} from "../atoms/paragraph-atoms";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
const numPages = usePdfStore((s) => s.pageCount);
const currentPage = usePdfStore((s) => s.pageNumber);
const pdfProxy = usePdfStore((s) => s.pdfDocumentProxy);
```

- [ ] **Step 6: Migrate `components/pdf/components/text-extractor.tsx`**

```typescript
// Remove:
import { backgroundPageAtom } from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
const pageNumber = usePdfStore((s) => s.backgroundPage);
```

- [ ] **Step 7: Migrate `components/pdf/components/background-page.tsx`**

```typescript
// Remove:
import {
  backgroundPageAtom,
  isTextItem,
} from "@components/pdf/atoms/paragraph-atoms";
import { useSetAtom } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Move the `isTextItem` helper into this file or into a shared utils file:

```typescript
import type { TextItem, TextMarkedContent } from "react-pdf";

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return "str" in item;
}
```

Replace:

```typescript
const setBackgroundPage = usePdfStore((s) => s.setBackgroundPage);
```

- [ ] **Step 8: Migrate `components/pdf/hooks/usePdfNavigation.tsx`**

```typescript
// Remove:
import {
  isDualPageAtom,
  nextPageAtom,
  pageCountAtom,
  previousPageAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtom, useAtomValue, useSetAtom } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
export function usePdfNavigation() {
  const numPages = usePdfStore((s) => s.pageCount);
  const setNumPages = usePdfStore((s) => s.setPageCount);
  const isDualPage = usePdfStore((s) => s.isDualPage);
  const previousPage = usePdfStore((s) => s.previousPage);
  const nextPage = usePdfStore((s) => s.nextPage);

  // ... window size logic stays the same ...

  return {
    previousPage,
    nextPage,
    setNumPages,
    numPages,
    isDualPage,
    pdfHeight,
    pdfWidth,
    dualPageWidth,
    isFullscreen,
  };
}
```

- [ ] **Step 9: Migrate `components/pdf/hooks/useScrolling.tsx`**

```typescript
// Remove:
import {
  highlightedParagraphAtom,
  isLookingForNextParagraphAtom,
  isTextGotAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";
import { customStore } from "@/stores/jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
export function useScrolling(scrollContainerRef: React.RefObject<HTMLDivElement | null>) {
  const highlightedParagraphIndex = usePdfStore((s) => s.highlightedParagraphIndex);
  const currentViewParagraphs = usePdfStore((s) => s.currentViewParagraphs);
  const highlightedParagraph = currentViewParagraphs.find(
    (p) => p.index === highlightedParagraphIndex
  );
  const isRendered = usePdfStore((s) => s.isTextGot);

  useEffect(() => {
    const container = scrollContainerRef.current;
    if (!container || !highlightedParagraph?.index) return;
    if (!isRendered) return;

    const timeout = setTimeout(() => {
      const el = [...container.querySelectorAll<HTMLElement>("mark")].find(
        (mark) => mark.innerText
      );
      if (!el) return;
      console.log({ el });
      const isLookingForNextParagraph = usePdfStore.getState().isLookingForNextParagraph;
      if (isLookingForNextParagraph) {
        return;
      }

      const containerRect = container.getBoundingClientRect();
      const elementRect = el.getBoundingClientRect();
      const currentScrollTop = container.scrollTop;
      const elementTopRelativeToContainer =
        elementRect.top - containerRect.top + currentScrollTop;
      const targetScrollTop =
        elementTopRelativeToContainer -
        container.clientHeight / 2 +
        elementRect.height / 2;

      animate(container.scrollTop, targetScrollTop, {
        duration: 0.8,
        ease: [0.4, 0, 0.2, 1],
        onUpdate: (latest) => {
          container.scrollTop = latest;
        },
      });
    }, 100);
    return () => clearTimeout(timeout);
  }, [highlightedParagraph, isRendered]);
}
```

- [ ] **Step 10: Migrate `components/pdf/hooks/useCurrentPageNumber.tsx`**

```typescript
// Remove:
import { useAtomValue, useSetAtom } from "jotai";
import {
  bookNavigationStateAtom,
  BookNavigationState,
  getCurrentViewParagraphsAtom,
  getNextViewParagraphsAtom,
  getPreviousViewParagraphsAtom,
  isTextGotAtom,
  pageNumberAtom,
  pageNumberToPageDataAtom,
  scrollPageNumberAtom,
  setPageNumberAtom,
} from "../atoms/paragraph-atoms";
import { customStore } from "@/stores/jotai";

// Add:
import { usePdfStore, BookNavigationState } from "@/stores/pdfStore";
```

Replace hook calls:

```typescript
export function useCurrentPageNumber(
  scrollRef: React.RefObject<HTMLDivElement | null>,
  book: Book,
  virtualizer?: Virtualizer<HTMLDivElement, Element>
) {
  const currentPageNumber = usePdfStore((s) => s.pageNumber);
  const setScrollPageNumber = usePdfStore((s) => s.setScrollPageNumber);
  const setPageNumber = usePdfStore((s) => s.setPageNumber);
  const setCurrentViewParagraphs = usePdfStore((s) => s.setCurrentViewParagraphs);
  const setIsTextGot = usePdfStore((s) => s.setIsTextGot);
  const setNextViewParagraphs = usePdfStore((s) => s.setNextViewParagraphs);
  const setPreviousViewParagraphs = usePdfStore((s) => s.setPreviousViewParagraphs);
  const bookId = book.id;
```

Replace all `customStore.get(...)` / `customStore.set(...)` with `usePdfStore.getState()...`:

```typescript
// Inside the setInterval callback:
const atomPageNumber = usePdfStore.getState().pageNumber;
const navigationState = usePdfStore.getState().bookNavigationState;

if (
  navigationState === BookNavigationState.Navigating &&
  visiblePageNumber === atomPageNumber
) {
  usePdfStore.getState().setBookNavigationState(BookNavigationState.Navigated);
}

if (
  visiblePageNumber !== atomPageNumber &&
  navigationState !== BookNavigationState.Navigating
) {
  setScrollPageNumber(visiblePageNumber);
}

const pageNumberToPageData = usePdfStore.getState().pageNumberToPageData;
// ... rest of the interval logic stays structurally the same,
// just replace customStore.get(xAtom) with usePdfStore.getState().x
```

And for the comparison reads:

```typescript
const currentViewParagraphs = usePdfStore.getState().currentViewParagraphs;
const nextViewParagraphs = usePdfStore.getState().nextViewParagraphs;
const previousViewParagraphs = usePdfStore.getState().previousViewParagraphs;
```

- [ ] **Step 11: Migrate `components/pdf/hooks/useSetupMenu.tsx`**

```typescript
// Remove:
import { isDualPageAtom } from "@components/pdf/atoms/paragraph-atoms";
import { customStore } from "@/stores/jotai";
import { useAtomValue } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace `customStore.get(isDualPageAtom)` → `usePdfStore.getState().isDualPage`.
Replace `customStore.set(isDualPageAtom, !current)` → `usePdfStore.getState().setDualPage(!current)`.
Replace `const isDualPage = useAtomValue(isDualPageAtom)` → `const isDualPage = usePdfStore((s) => s.isDualPage)`.

- [ ] **Step 12: Migrate `components/pdf/hooks/useVirualization.tsx`**

```typescript
// Remove:
import {
  hasNavigatedToPageAtom,
  pageCountAtom,
  virtualizerAtom,
} from "../atoms/paragraph-atoms";
import { useAtomValue, useSetAtom } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
const numPages = usePdfStore((s) => s.pageCount);
const setHasNavigatedToPage = usePdfStore((s) => s.setHasNavigatedToPage);
const setVirtualizer = usePdfStore((s) => s.setVirtualizer);
```

- [ ] **Step 13: Migrate `components/pdf/hooks/useUpdateCoverIMage.tsx`**

```typescript
// Remove:
import {
  hasNavigatedToPageAtom,
  isPdfRenderedAtom,
} from "@components/pdf/atoms/paragraph-atoms";
import { useAtomValue } from "jotai";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
```

Replace:

```typescript
export function useUpdateCoverIMage(book: Book) {
  const isPdfRendered = usePdfStore((s) => s.isPdfRendered);
  const hasNavigatedToPage = usePdfStore((s) => s.hasNavigatedToPage);
  useEffect(() => {
    if (isPdfRendered(book.id.toString()) && hasNavigatedToPage) {
      void updateStoredCoverImage(book);
    }
  }, [isPdfRendered, book, hasNavigatedToPage]);
}
```

- [ ] **Step 14: Migrate `components/FileComponent.tsx`**

```typescript
// Remove:
import { atom, useSetAtom } from "jotai";
import { customStore } from "@/stores/jotai";
import { pdfsControllerAtom } from "@components/pdf/atoms/paragraph-atoms";

// Add:
import { usePdfStore } from "@/stores/pdfStore";
import { useState, useEffect } from "react";
import { useNavigate } from "@tanstack/react-router";
```

Remove the `newBook` atom and `useNavigateToNewBook` hook. Replace with plain React state:

```typescript
// Remove:
// const newBook = atom<string | null>(null);
// const useNavigateToNewBook = () => { ... };

// Inside FileDrop, replace the newBook atom pattern with:
const navigate = useNavigate();
const [newBookId, setNewBookId] = useState<string | null>(null);

useEffect(() => {
  if (newBookId) {
    void navigate({ to: "/books/$id", params: { id: newBookId } });
    setNewBookId(null);
  }
}, [newBookId, navigate]);
```

Replace `useSetAtom(pdfsControllerAtom)` with store actions:

```typescript
const addBook = usePdfStore((s) => s.addBook);
const removeBook = usePdfStore((s) => s.removeBook);
const setAllBooks = usePdfStore((s) => s.setAllBooks);
```

Replace calls:
- `setPfsController({ type: "setAll", ids: pdfIds })` → `setAllBooks(pdfIds)`
- `setPfsController({ type: "remove", id: book.id })` → `removeBook(book.id)`

Replace `setNewBookId` usage (already using the `setNewBookId` from useState now, so the `useSetAtom(newBook)` and its reset+setTimeout pattern can be simplified):

```typescript
// In onSuccess callbacks, replace:
// setNewBookId(null);
// setTimeout(() => { setNewBookId(bookData.id.toString()); }, 0);
// With just:
setNewBookId(bookData.id.toString());
```

- [ ] **Step 15: Migrate `routes/books.$id.lazy.tsx`**

```typescript
// Remove:
import { useSetAtom } from "jotai";
import {
  bookAtom,
  BookNavigationState,
  bookNavigationStateAtom,
} from "@components/pdf/atoms/paragraph-atoms";

// Add:
import { usePdfStore, BookNavigationState } from "@/stores/pdfStore";
```

Replace:

```typescript
const setBook = usePdfStore((s) => s.setBook);
const setBookNavigationState = usePdfStore((s) => s.setBookNavigationState);
```

- [ ] **Step 16: Migrate `modules/updater.ts`**

```typescript
// Remove:
import { atom } from "jotai";
import { customStore } from "@/stores/jotai";

// Add:
import { create } from "zustand";
import { devtools } from "zustand/middleware";
```

Replace the atom with a tiny store:

```typescript
import { create } from "zustand";
import { devtools } from "zustand/middleware";

export type UpdateStatus =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "downloading"; downloaded: number; total: number }
  | { kind: "installing" }
  | { kind: "error"; message: string };

interface UpdateState {
  status: UpdateStatus;
  setStatus: (status: UpdateStatus) => void;
}

export const useUpdateStore = create<UpdateState>()(
  devtools(
    (set) => ({
      status: { kind: "idle" } as UpdateStatus,
      setStatus: (status) => set({ status }),
    }),
    { name: "update-store" }
  )
);
```

Replace all `customStore.set(updateStatusAtom, ...)` with `useUpdateStore.getState().setStatus(...)`.

Remove the standalone `updateStatusAtom` export.

- [ ] **Step 17: Update `components/UpdateMenu.tsx` to use the update store**

```typescript
// Remove:
import { useAtomValue } from "jotai";
import {
  checkForUpdates,
  renderStatus,
  updateStatusAtom,
} from "@/modules/updater";

// Add:
import { checkForUpdates, renderStatus, useUpdateStore } from "@/modules/updater";
```

Replace:

```typescript
const status = useUpdateStore((s) => s.status);
```

- [ ] **Step 18: Verify the app compiles**

```bash
cd apps/main && bun run build
```

- [ ] **Step 19: Commit**

```bash
git add apps/main/src/stores/pdfStore.ts apps/main/src/components/pdf/ apps/main/src/components/FileComponent.tsx apps/main/src/routes/books.\$id.lazy.tsx apps/main/src/modules/updater.ts apps/main/src/components/UpdateMenu.tsx
git commit -m "refactor: migrate PDF state and updater from Jotai to Zustand stores"
```

---

### Task 6: Clean Up Event Bus and Remove Jotai

**Files:**
- Modify: `apps/main/src/utils/bus.ts` (remove atom exports)
- Delete: `apps/main/src/stores/jotai.ts`
- Delete: `apps/main/src/stores/epub_atoms.ts`
- Delete: `apps/main/src/stores/chat_atoms.ts`
- Delete: `apps/main/src/atoms/authPromo.ts`
- Delete: `apps/main/src/components/pdf/atoms/paragraph-atoms.ts`
- Delete: `apps/main/src/components/pdf/atoms/user.ts`
- Delete: `apps/main/src/utils/atoms.ts`
- Modify: `apps/main/src/components/providers.tsx`
- Modify: `apps/main/package.json` (remove jotai deps)

- [ ] **Step 1: Clean up `utils/bus.ts`**

Remove the Jotai atom exports at the bottom of the file:

```typescript
// Remove these lines:
import { atom } from "jotai";

export const eventBusAtom = atom(eventBus);
eventBusAtom.debugLabel = "eventBusAtom";
export const eventBusLogsAtom = atom((get) => get(eventBusAtom).logsBugger);
eventBusLogsAtom.debugLabel = "eventBusLogsAtom";
```

Keep everything else (the `EventBus` class, `eventBus` singleton, enums, types).

- [ ] **Step 2: Remove Jotai provider from `providers.tsx`**

```typescript
// Remove:
import { Provider } from "jotai";
import { DevTools } from "jotai-devtools";
import "jotai-devtools/styles.css";
import { customStore } from "@/stores/jotai";
```

Replace the component body:

```typescript
function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <div>
      <QueryClientProvider client={queryClient}>
        {children}
      </QueryClientProvider>
      <ToastContainer />
    </div>
  );
}
```

- [ ] **Step 3: Delete old Jotai files**

```bash
rm apps/main/src/stores/jotai.ts
rm apps/main/src/stores/epub_atoms.ts
rm apps/main/src/stores/chat_atoms.ts
rm apps/main/src/atoms/authPromo.ts
rm apps/main/src/components/pdf/atoms/paragraph-atoms.ts
rm apps/main/src/components/pdf/atoms/user.ts
rm apps/main/src/utils/atoms.ts
```

- [ ] **Step 4: Remove Jotai dependencies**

```bash
cd apps/main && bun remove jotai jotai-devtools jotai-effect jotai-immer
```

- [ ] **Step 5: Verify the app compiles with no Jotai references**

```bash
cd apps/main && bun run build
```

Expected: Clean build, zero references to jotai anywhere.

- [ ] **Step 6: Search for any remaining Jotai imports**

```bash
grep -r "from.*jotai" apps/main/src/ --include="*.ts" --include="*.tsx" || echo "No Jotai imports found — clean!"
```

If any remain, fix them.

- [ ] **Step 7: Commit**

```bash
git add -A apps/main/
git commit -m "refactor: remove Jotai and all old atom files — migration complete"
```

---

### Task 7: Smoke Test and Final Verification

- [ ] **Step 1: Run the type checker**

```bash
cd apps/main && npx tsc --noEmit
```

Expected: No type errors.

- [ ] **Step 2: Run existing tests**

```bash
cd apps/main && bun run test --run
```

Expected: All existing tests pass.

- [ ] **Step 3: Build the Tauri app**

```bash
cd apps/main && bun run build
```

Expected: Clean build.

- [ ] **Step 4: Commit any final fixes**

If any test or type issues were found and fixed:

```bash
git add -A apps/main/
git commit -m "fix: resolve post-migration type and test issues"
```
