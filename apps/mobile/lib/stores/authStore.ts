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
 *   - `clearSession()` wipes both the in-memory + persisted user id and flips
 *     `isAuthenticated` to false. `lib/auth.signOut()` calls
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
  openPremiumGate: (feature: PremiumFeature) => void
  closePremiumGate: () => void
}

export const useAuthStore = create<AuthState>()((set) => ({
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
    set({
      sessionToken: token,
      user: { id: userId, email },
      isAuthenticated: true,
      isAuthenticating: false,
    })
    try {
      bucket.setItem(USER_ID_KEY, userId)
    } catch (err) {
      console.warn('[authStore] failed to persist user id:', err)
    }
  },

  clearSession: () => {
    set({
      sessionToken: null,
      user: null,
      isAuthenticated: false,
      isAuthenticating: false,
    })
    try {
      bucket.removeItem(USER_ID_KEY)
    } catch (err) {
      console.warn('[authStore] failed to clear persisted user id:', err)
    }
  },

  setAuthenticating: (value) => set({ isAuthenticating: value }),

  openPremiumGate: (feature) =>
    set({ premiumGateOpen: true, premiumGateFeature: feature }),
  closePremiumGate: () =>
    set({ premiumGateOpen: false, premiumGateFeature: null }),
}))
