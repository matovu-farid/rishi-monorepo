import { useEffect } from 'react'
import { useAuthStore } from '@/stores/authStore'

/**
 * Root-level hook: runs exactly once on app mount.
 *
 * Hydrates the welcome-seen flag from localStorage, then asks the main
 * process for the current Better Auth session via IPC. After the initial
 * fetch, subscribes to `session-changed` so the renderer reflects future
 * sign-in / sign-out / delete-account events without a manual refresh.
 *
 * Sign-in itself is initiated by `<SignInModal>` (magic-link form) or
 * `<LoginButton>` and completed by the deep-link handler in the main
 * process; once the main process broadcasts the new session, this hook
 * stores the user and closes any open sign-in modal.
 */
export function useHydrateAuth(): void {
  const setUser = useAuthStore((s) => s.setUser)
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated)
  const hydrateAuth = useAuthStore((s) => s.hydrateAuth)
  const closeSignIn = useAuthStore((s) => s.closeSignIn)

  useEffect(() => {
    hydrateAuth()
    void window.api.auth
      .getSession()
      .then((user) => {
        setUser(user)
      })
      .catch((err: unknown) => {
        console.error('[useHydrateAuth] failed to load session:', err)
        setUser(null)
      })
      .finally(() => {
        setAuthHydrated(true)
      })
    const off = window.api.auth.onSessionChange((user) => {
      setUser(user)
      if (user) closeSignIn()
    })
    return off
  }, [setUser, setAuthHydrated, hydrateAuth, closeSignIn])
}
