import { useEffect } from 'react'
import { useAuthStore } from '@/stores/authStore'
import { getSyncService } from '@/services'

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
 *
 * On every sign-in transition (null -> user) we also kick a sync push so
 * any books imported while signed-out are uploaded immediately instead of
 * waiting for the 5-minute periodic timer.
 */
export function useHydrateAuth(): void {
  const setUser = useAuthStore((s) => s.setUser)
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated)
  const hydrateAuth = useAuthStore((s) => s.hydrateAuth)
  const closeSignIn = useAuthStore((s) => s.closeSignIn)

  useEffect(() => {
    hydrateAuth()
    let lastUserId: string | null = null
    void window.api.auth
      .getSession()
      .then((user) => {
        setUser(user)
        lastUserId = user?.id ?? null
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
      // Fire-and-forget push on sign-in. SyncService.triggerWrite() debounces
      // and runs a full sync cycle (push then pull) — exactly what we want
      // after sign-in: ship any local writes from the signed-out session,
      // then pull whatever the cloud has. We only trigger on user-id flips
      // so a token refresh that keeps the same user doesn't spam the worker.
      const newUserId = user?.id ?? null
      if (newUserId && newUserId !== lastUserId) {
        try {
          getSyncService().triggerWrite()
        } catch (err) {
          console.warn('[useHydrateAuth] post-sign-in sync trigger failed', err)
        }
      }
      lastUserId = newUserId
    })
    return off
  }, [setUser, setAuthHydrated, hydrateAuth, closeSignIn])
}
