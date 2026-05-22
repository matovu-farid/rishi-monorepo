/**
 * Sign-in screen — Better-Auth deep-link flow (Batch 1C). Replaces the
 * Clerk-based form.
 *
 * UX:
 *   - Two primary buttons: "Continue with Google" and "Sign in with Email".
 *     Google opens the in-app browser to the worker /mobile/start
 *     authUrl; email/password opens the same browser but with
 *     `provider=password` (the web app handles the email/password form).
 *   - During the round-trip, the screen shows a spinner driven by
 *     `authStore.isAuthenticating`.
 *   - On success, `lib/auth.signIn()` persists the bearer to secure-store
 *     and pushes the session into `authStore`. The (tabs) layout
 *     observes `isAuthenticated` and redirects us into the app.
 */
import { useRouter, type Href } from 'expo-router'
import { useCallback, useState } from 'react'
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Text,
  TouchableOpacity,
  View,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'

import { signIn, type AuthProvider } from '@/lib/auth'
import { useAuthStore } from '@/lib/stores/authStore'

export default function SignInScreen() {
  const router = useRouter()
  const isAuthenticating = useAuthStore((s) => s.isAuthenticating)
  const setAuthenticating = useAuthStore((s) => s.setAuthenticating)
  const setSession = useAuthStore((s) => s.setSession)
  const [error, setError] = useState<string | null>(null)

  const startSignIn = useCallback(
    async (provider: AuthProvider) => {
      setError(null)
      setAuthenticating(true)
      try {
        const { session_token, user_id } = await signIn(provider)
        // lib/auth.ts already persisted the token to expo-secure-store.
        // Mirror it into the in-memory store so the UI re-renders before
        // the next hydrateAuth() cycle.
        setSession(session_token, user_id)
        router.replace('/' as Href)
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err)
        // Cancellations are not user-facing errors.
        if (!/cancel|dismiss/i.test(msg)) {
          setError(msg)
        }
      } finally {
        setAuthenticating(false)
      }
    },
    [router, setAuthenticating, setSession],
  )

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-black">
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        className="flex-1 justify-center px-6"
      >
        <Text
          testID="sign-in-title"
          className="text-3xl font-bold text-center mb-2 text-gray-900 dark:text-white"
        >
          Welcome to Rishi
        </Text>
        <Text className="text-center mb-8 text-gray-600 dark:text-gray-400">
          Sign in to sync your library across devices.
        </Text>

        {error ? (
          <Text testID="sign-in-error" className="text-red-500 text-center mb-4">
            {error}
          </Text>
        ) : null}

        <TouchableOpacity
          testID="google-sign-in-button"
          className="bg-blue-600 rounded-lg py-3 mb-4"
          onPress={() => startSignIn('google')}
          disabled={isAuthenticating}
        >
          {isAuthenticating ? (
            <ActivityIndicator color="white" />
          ) : (
            <Text className="text-white text-center font-semibold text-lg">
              Continue with Google
            </Text>
          )}
        </TouchableOpacity>

        <View className="flex-row items-center mb-4">
          <View className="flex-1 h-px bg-gray-300 dark:bg-gray-600" />
          <Text className="mx-4 text-gray-500">or</Text>
          <View className="flex-1 h-px bg-gray-300 dark:bg-gray-600" />
        </View>

        <TouchableOpacity
          testID="email-sign-in-button"
          className="border border-gray-300 dark:border-gray-600 rounded-lg py-3"
          onPress={() => startSignIn('password')}
          disabled={isAuthenticating}
        >
          <Text className="text-center font-semibold text-gray-700 dark:text-gray-300">
            Sign in with Email
          </Text>
        </TouchableOpacity>

        {/*
          P1-Q — Create-account CTA. Without this, brand-new users have no
          obvious path to register from the sign-in screen. We re-use the
          existing sign-in flow with provider='signup', which the worker
          routes to the registration form.
        */}
        <TouchableOpacity
          testID="create-account-button"
          accessibilityRole="button"
          accessibilityLabel="Create account"
          accessibilityHint="Opens a secure browser to register a new Rishi account."
          className="mt-4 py-3"
          onPress={() => startSignIn('signup')}
          disabled={isAuthenticating}
        >
          <Text className="text-center text-base font-semibold text-blue-600 dark:text-blue-400">
            Create account
          </Text>
        </TouchableOpacity>

        {/*
          P1-D — tertiary escape hatch. Without this, signed-out users who
          arrive at the sign-in screen (deep link, gate handoff, etc.) have
          no way back to the local library. Routes to the tabs root.
        */}
        <TouchableOpacity
          testID="skip-for-now-button"
          accessibilityRole="button"
          accessibilityLabel="Skip for now"
          accessibilityHint="Browse your local books without signing in."
          className="mt-2 py-3"
          onPress={() => router.replace('/(tabs)' as Href)}
          disabled={isAuthenticating}
        >
          <Text className="text-center text-base text-gray-500 dark:text-gray-400">
            Skip for now
          </Text>
        </TouchableOpacity>
      </KeyboardAvoidingView>
    </SafeAreaView>
  )
}
