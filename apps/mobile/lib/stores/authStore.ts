/**
 * Mobile authStore — ported from
 * `apps/rishi-electron/src/renderer/src/stores/authStore.ts` and extended
 * for the Better-Auth deep-link flow (Batch 1C).
 *
 * Persisted state (MMKV under `rishi.mobile.auth:`):
 *   - `welcome-seen`        — has the onboarding welcome banner been dismissed?
 *   - `user-id`             — last signed-in user id, restored on next launch.
 *
 * NOT persisted here:
 *   - `sessionToken` lives in `expo-secure-store` (see `lib/auth.ts`). MMKV is
 *     not appropriate for a bearer token.
 *
 * Behavioural notes:
 *   - `setSession(token, userId)` writes the token into the in-memory store
 *     (handy for hooks that need a synchronous render), persists `userId` to
 *     MMKV, and flips `isAuthenticated` to true. It does NOT persist the
 *     token itself — `lib/auth.signIn()` writes to secure-store before
 *     calling this.
 *   - `clearSession()` wipes both the in-memory + persisted user id, flips
 *     `isAuthenticated` to false, and clears `dismissedFeatures` /
 *     `pendingAction` so a re-auth (or different user) starts from a clean
 *     gate state (GAT-101 / GAT-102). `lib/auth.signOut()` calls
 *     `SecureStore.deleteItemAsync` to remove the actual bearer.
 *   - `isAuthenticating` is a UI flag for the sign-in screen's loading state.
 */
import { create } from 'zustand'
import type { PremiumFeature } from '@rishi/shared/auth-gating'
import { createStorage } from '@/lib/storage/mmkv'
import { useTutorialStore } from './tutorialStore'
import { getSessionToken } from '@/lib/auth'

const bucket = createStorage('rishi.mobile.auth')
const WELCOME_SEEN_KEY = 'welcome-seen'
const USER_ID_KEY = 'user-id'

/**
 * Minimal AuthUser shape — matches the subset of electron's `AuthUser`
 * that the renderer reads. Mobile populates this from Better-Auth.
 */
export interface AuthUser {
  id: string
  email: string | null
}

interface AuthState {
  user: AuthUser | null
  authHydrated: boolean
  welcomeSeen: boolean
  bannerDismissed: boolean
  signInOpen: boolean

  // Batch 1C — session token surface (token itself lives in expo-secure-store).
  sessionToken: string | null
  isAuthenticated: boolean
  isAuthenticating: boolean

  // Phase 1 (mobile parity v2) — premium feature gate sheet.
  premiumGateOpen: boolean
  premiumGateFeature: PremiumFeature | null

  // P0-U: deferred action to replay after the gated user signs in.
  // When `openPremiumGate(feature, action)` is called, `action` is stashed
  // here. `setSession` invokes it on successful sign-in and clears it.
  // `closePremiumGate` (dismiss / "Not now") discards it without invoking.
  pendingAction: (() => void) | null

  // P1-R: session-only set of features the user has explicitly dismissed
  // via the premium gate sheet's "Maybe later". Surfaces (reader / chat)
  // check this set to hide or disable the gated control so the gate
  // cannot be re-triggered. NOT persisted — it resets on cold start so
  // signed-out users still get a fresh prompt on their next launch.
  dismissedFeatures: Set<PremiumFeature>

  // Actions
  setUser: (user: AuthUser | null) => void
  setAuthHydrated: (value: boolean) => void
  /**
   * H1-04: full cold-start hydration. Reads `welcome-seen` + `user-id` from
   * MMKV AND the bearer token from expo-secure-store. Sets
   * `authHydrated: true` unconditionally at the end so route guards in
   * `(tabs)/_layout.tsx` un-block even when `(auth)/_layout.tsx` never
   * mounts (the common case for already-signed-in users on cold-start).
   *
   * Returns a promise so the root layout can `await` it, but the existing
   * fire-and-forget call sites still work (the promise just resolves
   * once the secure-store read completes).
   */
  hydrateAuth: () => Promise<void>
  dismissBanner: () => void
  dismissWelcome: () => void
  setWelcomeSeen: () => void
  openSignIn: () => void
  closeSignIn: () => void

  // Batch 1C actions
  setSession: (token: string, userId: string, email?: string | null) => void
  clearSession: () => void
  setAuthenticating: (value: boolean) => void

  // Phase 1 — premium gate actions
  openPremiumGate: (feature: PremiumFeature, action?: () => void) => void
  closePremiumGate: () => void
}

export const useAuthStore = create<AuthState>()((set, get) => ({
  user: null,
  authHydrated: false,
  welcomeSeen: false,
  bannerDismissed: false,
  signInOpen: false,

  sessionToken: null,
  isAuthenticated: false,
  isAuthenticating: false,

  premiumGateOpen: false,
  premiumGateFeature: null,
  pendingAction: null,
  dismissedFeatures: new Set<PremiumFeature>(),

  setUser: (user) => set({ user }),
  setAuthHydrated: (value) => set({ authHydrated: value }),
  openSignIn: () => set({ signInOpen: true }),
  closeSignIn: () => set({ signInOpen: false }),

  hydrateAuth: async () => {
    try {
      const value = bucket.getItem(WELCOME_SEEN_KEY)
      set({ welcomeSeen: value === '1' })
    } catch (err) {
      console.warn('[authStore] failed to read welcome-seen flag, fail-closing:', err)
      set({ welcomeSeen: true })
    }

    // Restore last-known user id so the UI knows who we were before the
    // session-token round-trip completes.
    let persistedUserId: string | null = null
    try {
      const userId = bucket.getItem(USER_ID_KEY)
      if (userId) {
        persistedUserId = userId
        set({ user: { id: userId, email: null } })
      }
    } catch (err) {
      console.warn('[authStore] failed to read persisted user id:', err)
    }

    // H1-04: read the bearer from expo-secure-store ourselves. Previously
    // this lived in `(auth)/_layout.tsx`'s effect, which never ran for
    // returning users who landed on `/(tabs)` — leaving `authHydrated`
    // false forever and `(tabs)/_layout.tsx` showing a blank screen.
    try {
      const token = await getSessionToken()
      if (token && persistedUserId) {
        set({
          sessionToken: token,
          user: { id: persistedUserId, email: null },
          isAuthenticated: true,
          isAuthenticating: false,
        })
      }
    } catch (err) {
      console.warn('[authStore] failed to read session token:', err)
    } finally {
      // Whether or not we found a session, the cold-start hydration is
      // done — route guards can stop blocking on `!authHydrated`.
      set({ authHydrated: true })
    }
  },

  dismissBanner: () => set({ bannerDismissed: true }),

  dismissWelcome: () => {
    set({ welcomeSeen: true, bannerDismissed: true })
    try {
      bucket.setItem(WELCOME_SEEN_KEY, '1')
    } catch (err) {
      console.warn('[authStore] failed to persist welcome-seen flag:', err)
    }
    // Start onboarding tour if not completed
    const { tourCompleted, startTour } = useTutorialStore.getState()
    if (!tourCompleted) {
      setTimeout(startTour, 400)
    }
  },

  setWelcomeSeen: () => {
    set({ welcomeSeen: true })
    try {
      bucket.setItem(WELCOME_SEEN_KEY, '1')
    } catch (err) {
      console.warn('[authStore] failed to persist welcome-seen flag:', err)
    }
    // Start onboarding tour if not completed
    const { tourCompleted, startTour } = useTutorialStore.getState()
    if (!tourCompleted) {
      setTimeout(startTour, 400)
    }
  },

  setSession: (token, userId, email = null) => {
    // P0-U: snapshot any pending gated action BEFORE flipping state so the
    // closure observes the post-sign-in store on replay.
    const pending = get().pendingAction
    set({
      sessionToken: token,
      user: { id: userId, email },
      isAuthenticated: true,
      isAuthenticating: false,
      pendingAction: null,
      // P1-R: clear dismissed-features on successful sign-in so the user
      // immediately sees the now-unlocked controls.
      dismissedFeatures: new Set<PremiumFeature>(),
    })
    try {
      bucket.setItem(USER_ID_KEY, userId)
    } catch (err) {
      console.warn('[authStore] failed to persist user id:', err)
    }
    if (pending) {
      try {
        pending()
      } catch (err) {
        console.warn('[authStore] pendingAction replay failed:', err)
      }
    }
  },

  clearSession: () => {
    // GAT-101 / GAT-102 (#74 / #75): sign-out — whether explicit ("Sign out"
    // button) or forced (apiClient 401 handler) — must wipe the session-only
    // `dismissedFeatures` set. Otherwise the next user to sign in on this
    // device (account-switch on a shared phone, re-auth after a 401, etc.)
    // inherits the previous user's premium-gate dismissals and the
    // surfaces stay hidden until the next cold start.
    //
    // Also clear `pendingAction` so a stashed gated-tap from before the
    // sign-out cannot replay against the next session.
    set({
      sessionToken: null,
      user: null,
      isAuthenticated: false,
      isAuthenticating: false,
      pendingAction: null,
      dismissedFeatures: new Set<PremiumFeature>(),
    })
    try {
      bucket.removeItem(USER_ID_KEY)
    } catch (err) {
      console.warn('[authStore] failed to clear persisted user id:', err)
    }
  },

  setAuthenticating: (value) => set({ isAuthenticating: value }),

  openPremiumGate: (feature, action) =>
    set({
      premiumGateOpen: true,
      premiumGateFeature: feature,
      // Replace any prior pending action — only the latest gated tap
      // should be replayed on sign-in.
      pendingAction: action ?? null,
    }),
  closePremiumGate: () => {
    // P0-U: dismissing the gate (e.g. "Maybe later") discards the pending
    // action so it can never be replayed later.
    // P1-R: also record the dismissed feature so the surface that opened
    // the gate can hide its gated control until the next cold start.
    const feature = get().premiumGateFeature
    const next =
      feature != null
        ? new Set<PremiumFeature>(get().dismissedFeatures).add(feature)
        : get().dismissedFeatures
    set({
      premiumGateOpen: false,
      premiumGateFeature: null,
      pendingAction: null,
      dismissedFeatures: next,
    })
  },
}))
