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
import { createStorage } from '@/lib/storage/mmkv'
import { useTutorialStore } from './tutorialStore'

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

  // Actions
  setUser: (user: AuthUser | null) => void
  setAuthHydrated: (value: boolean) => void
  hydrateAuth: () => void
  dismissBanner: () => void
  dismissWelcome: () => void
  setWelcomeSeen: () => void
  openSignIn: () => void
  closeSignIn: () => void

  // Batch 1C actions
  setSession: (token: string, userId: string, email?: string | null) => void
  clearSession: () => void
  setAuthenticating: (value: boolean) => void
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

  setUser: (user) => set({ user }),
  setAuthHydrated: (value) => set({ authHydrated: value }),
  openSignIn: () => set({ signInOpen: true }),
  closeSignIn: () => set({ signInOpen: false }),

  hydrateAuth: () => {
    try {
      const value = bucket.getItem(WELCOME_SEEN_KEY)
      set({ welcomeSeen: value === '1' })
    } catch (err) {
      console.warn('[authStore] failed to read welcome-seen flag, fail-closing:', err)
      set({ welcomeSeen: true })
    }

    // Restore last-known user id so the UI knows who we were before the
    // session-token round-trip completes. The token itself is read from
    // expo-secure-store by `lib/auth.ts` and pushed into the store via
    // `setSession`.
    try {
      const userId = bucket.getItem(USER_ID_KEY)
      if (userId) {
        set({ user: { id: userId, email: null } })
      }
    } catch (err) {
      console.warn('[authStore] failed to read persisted user id:', err)
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
}))
