import { Redirect, Stack } from 'expo-router'

import { useAuthStore } from '@/lib/stores/authStore'
import { IS_E2E_TEST } from '@/app/_layout'

export default function AuthLayout() {
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)

  // H1-04: cold-start hydration (secure-store read + MMKV read + flag flip)
  // now lives in `authStore.hydrateAuth()` and is driven by the root layout.
  // The auth layout only needs to consult `authHydrated` + `isAuthenticated`.

  if (IS_E2E_TEST) return <Redirect href="/(tabs)" />
  if (!authHydrated) return null
  if (isAuthenticated) return <Redirect href="/(tabs)" />

  return <Stack screenOptions={{ headerShown: false }} />
}
