import { useAuth } from '@clerk/expo'
import { Redirect, Stack } from 'expo-router'
import { IS_E2E_TEST } from '@/app/_layout'

export default function AuthLayout() {
  // Always call hooks before any conditional returns (rules-of-hooks).
  const { isSignedIn, isLoaded } = useAuth()

  if (IS_E2E_TEST) return <Redirect href="/(tabs)" />
  if (!isLoaded) return null
  if (isSignedIn) return <Redirect href="/(tabs)" />

  return <Stack screenOptions={{ headerShown: false }} />
}
