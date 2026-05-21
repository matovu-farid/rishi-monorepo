/**
 * Mobile authStore — ported from
 * `apps/rishi-electron/src/renderer/src/stores/authStore.ts`.
 *
 * Behaviour identical to electron, with the following swaps:
 *   - `localStorage.getItem('rishi:welcome-seen')` → MMKV (`welcome-seen` in
 *     the `rishi.mobile.auth` bucket).
 *   - `AuthUser` type imported from the local `@/types/auth` instead of
 *     electron's `../../preload/types`.
 *
 * Token persistence is intentionally NOT in this store. Mobile JWTs live
 * in `expo-secure-store` (see `lib/auth.ts`); electron uses `safeStorage`
 * via main-process IPC. Each platform's token cache stays where it is.
 */
import { create } from 'zustand'
import { createStorage } from '@/lib/storage/mmkv'
import { useTutorialStore } from './tutorialStore'

const bucket = createStorage('rishi.mobile.auth')
const WELCOME_SEEN_KEY = 'welcome-seen'

/**
 * Minimal AuthUser shape — matches the subset of electron's `AuthUser`
 * that the renderer reads. Mobile callers populate this from Clerk.
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

  // Actions
  setUser: (user: AuthUser | null) => void
  setAuthHydrated: (value: boolean) => void
  hydrateAuth: () => void
  dismissBanner: () => void
  dismissWelcome: () => void
  setWelcomeSeen: () => void
  openSignIn: () => void
  closeSignIn: () => void
}

export const useAuthStore = create<AuthState>()((set) => ({
  user: null,
  authHydrated: false,
  welcomeSeen: false,
  bannerDismissed: false,
  signInOpen: false,

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
}))
