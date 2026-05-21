import { Redirect, Stack } from 'expo-router'
import { useEffect } from 'react'

import { useAuthStore } from '@/lib/stores/authStore'
import { getSessionToken } from '@/lib/auth'
import { IS_E2E_TEST } from '@/app/_layout'

export default function AuthLayout() {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const setSession = useAuthStore((s) => s.setSession)
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated)
  const user = useAuthStore((s) => s.user)

  // Hydrate the in-memory store from expo-secure-store + MMKV exactly once.
  // The token lives in secure-store; the user id is restored from MMKV by
  // `useAuthStore.hydrateAuth()` (called by the root layout earlier).
  useEffect(() => {
    if (authHydrated) return
    let cancelled = false
    void (async () => {
      const token = await getSessionToken()
      if (cancelled) return
      if (token && user?.id) {
        setSession(token, user.id)
      }
      setAuthHydrated(true)
    })()
    return () => {
      cancelled = true
    }
  }, [authHydrated, user?.id, setSession, setAuthHydrated])

  if (IS_E2E_TEST) return <Redirect href="/(tabs)" />
  if (!authHydrated) return null
  if (isAuthenticated) return <Redirect href="/(tabs)" />

  return <Stack screenOptions={{ headerShown: false }} />
}
