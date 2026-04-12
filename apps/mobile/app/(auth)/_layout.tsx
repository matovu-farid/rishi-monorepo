import { useAuth } from '@clerk/expo'
import { Redirect, Stack } from 'expo-router'
import { IS_E2E_TEST } from '@/app/_layout'

export default function AuthLayout() {
  if (IS_E2E_TEST) return <Redirect href="/(tabs)" />

  const { isSignedIn, isLoaded } = useAuth()

  if (!isLoaded) return null
  if (isSignedIn) return <Redirect href="/(tabs)" />

  return <Stack screenOptions={{ headerShown: false }} />
}
