import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import type { AuthUser } from '../../../preload/types'
import { useTutorialStore } from './tutorialStore'

const WELCOME_SEEN_KEY = 'rishi:welcome-seen'

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

export const useAuthStore = create<AuthState>()(
  devtools(
    (set) => ({
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
          const value = localStorage.getItem(WELCOME_SEEN_KEY)
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
          localStorage.setItem(WELCOME_SEEN_KEY, '1')
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
          localStorage.setItem(WELCOME_SEEN_KEY, '1')
        } catch (err) {
          console.warn('[authStore] failed to persist welcome-seen flag:', err)
        }
        // Start onboarding tour if not completed
        const { tourCompleted, startTour } = useTutorialStore.getState()
        if (!tourCompleted) {
          setTimeout(startTour, 400)
        }
      }
    }),
    { name: 'auth-store' }
  )
)
