import { useEffect } from 'react'
import { useAuthStore } from '@/stores/authStore'

/**
 * Root-level hook: runs exactly once on app mount.
 *
 * Hydrates `welcomeSeen` from localStorage, dev-mode flag from the main
 * process, and the cached user profile from the JSON store. Sets
 * `authHydrated = true` so promo UI can decide what to show.
 *
 * Sign-in itself is handled by Clerk's <SignIn /> component rendered in
 * <SignInModal> (see ClerkAuthSync for Clerk → Zustand sync).
 */
export function useHydrateAuth(): void {
  const setUser = useAuthStore((s) => s.setUser)
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated)
  const hydrateWelcomeSeen = useAuthStore((s) => s.hydrateAuth)
  const setDevMode = useAuthStore((s) => s.setDevMode)

  useEffect(() => {
    hydrateWelcomeSeen()

    void (async () => {
      try {
        const dev = await window.electron.isDev()
        setDevMode(dev)
      } catch {
        /* ignore */
      }
      try {
        const user = await window.electron.getUserFromStore()
        setUser(user)
      } catch (err) {
        setUser(null)
        console.error('[useHydrateAuth] failed to load user from store:', err)
      } finally {
        setAuthHydrated(true)
      }
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
}
