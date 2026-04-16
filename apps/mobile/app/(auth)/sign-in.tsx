import { useSignIn } from '@clerk/expo'
import { useSignInWithGoogle } from '@clerk/expo/google'
import { useRouter, type Href } from 'expo-router'
import { useState, useCallback } from 'react'
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'

export default function SignInScreen() {
  const { signIn } = useSignIn()
  const { startGoogleAuthenticationFlow } = useSignInWithGoogle()
  const router = useRouter()

  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const onSignIn = useCallback(async () => {
    if (!signIn) return

    setLoading(true)
    setError('')

    try {
      const { error: signInError } = await signIn.password({
        emailAddress: email,
        password,
      })

      if (signInError) {
        setError(signInError.longMessage || signInError.message || 'Sign in failed')
        return
      }

      if (signIn.status === 'complete') {
        await signIn.finalize({
          navigate: ({ session }) => {
            if (session?.currentTask) {
              return
            }
            router.replace('/(tabs)' as Href)
          },
        })
      } else {
        setError('Sign in could not be completed. Please try again.')
      }
    } catch (err: any) {
      const message = err?.errors?.[0]?.longMessage || err?.errors?.[0]?.message || 'Sign in failed'
      setError(message)
    } finally {
      setLoading(false)
    }
  }, [signIn, email, password, router])

  const onGoogleSignIn = useCallback(async () => {
    if (Platform.OS !== 'ios' && Platform.OS !== 'android') return

    try {
      const { createdSessionId, setActive } = await startGoogleAuthenticationFlow()
      if (createdSessionId && setActive) {
        await setActive({ session: createdSessionId })
        router.replace('/(tabs)' as Href)
      }
    } catch (err: any) {
      if (err.code === 'SIGN_IN_CANCELLED' || err.code === '-5') return
      const message = err?.errors?.[0]?.longMessage || 'Google sign in failed'
      setError(message)
    }
  }, [startGoogleAuthenticationFlow, router])

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-black">
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        className="flex-1 justify-center px-6"
      >
        <Text testID="sign-in-title" className="text-3xl font-bold text-center mb-8 text-gray-900 dark:text-white">
          Welcome to Rishi
        </Text>

        {error ? (
          <Text className="text-red-500 text-center mb-4">{error}</Text>
        ) : null}

        <TextInput
          testID="email-input"
          className="border border-gray-300 dark:border-gray-600 rounded-lg px-4 py-3 mb-4 text-gray-900 dark:text-white bg-white dark:bg-gray-800"
          placeholder="Email"
          placeholderTextColor="#9CA3AF"
          value={email}
          onChangeText={setEmail}
          autoCapitalize="none"
          keyboardType="email-address"
          autoComplete="email"
        />

        <TextInput
          testID="password-input"
          className="border border-gray-300 dark:border-gray-600 rounded-lg px-4 py-3 mb-6 text-gray-900 dark:text-white bg-white dark:bg-gray-800"
          placeholder="Password"
          placeholderTextColor="#9CA3AF"
          value={password}
          onChangeText={setPassword}
          secureTextEntry
          autoComplete="password"
        />

        <TouchableOpacity
          testID="sign-in-button"
          className="bg-blue-600 rounded-lg py-3 mb-4"
          onPress={onSignIn}
          disabled={loading}
        >
          {loading ? (
            <ActivityIndicator color="white" />
          ) : (
            <Text className="text-white text-center font-semibold text-lg">Sign In</Text>
          )}
        </TouchableOpacity>

        <View className="flex-row items-center mb-4">
          <View className="flex-1 h-px bg-gray-300 dark:bg-gray-600" />
          <Text className="mx-4 text-gray-500">or</Text>
          <View className="flex-1 h-px bg-gray-300 dark:bg-gray-600" />
        </View>

        <TouchableOpacity
          testID="google-sign-in-button"
          className="border border-gray-300 dark:border-gray-600 rounded-lg py-3"
          onPress={onGoogleSignIn}
        >
          <Text className="text-center font-semibold text-gray-700 dark:text-gray-300">
            Continue with Google
          </Text>
        </TouchableOpacity>
      </KeyboardAvoidingView>
    </SafeAreaView>
  )
}
