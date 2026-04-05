import { useAuth, useUser } from '@clerk/expo'
import { useRouter } from 'expo-router'
import { useCallback, useEffect, useState } from 'react'
import {
  View,
  Text,
  TouchableOpacity,
  ActivityIndicator,
  ScrollView,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { apiClient } from '@/lib/api'
import { clearWorkerToken } from '@/lib/auth'

export default function HomeScreen() {
  const { signOut } = useAuth()
  const { user } = useUser()
  const router = useRouter()
  const [healthStatus, setHealthStatus] = useState<string | null>(null)
  const [apiError, setApiError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const checkHealth = useCallback(async () => {
    setLoading(true)
    setApiError(null)
    try {
      const response = await apiClient('/health')
      const data = await response.json()
      setHealthStatus(data.status || 'unknown')
    } catch (err: any) {
      setApiError(err.message || 'API call failed')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    checkHealth()
  }, [checkHealth])

  const handleSignOut = useCallback(async () => {
    await clearWorkerToken()
    await signOut()
    router.replace('/(auth)/sign-in')
  }, [signOut, router])

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-black">
      <ScrollView className="flex-1 px-6 pt-12">
        <Text className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
          Welcome{user?.firstName ? `, ${user.firstName}` : ''}
        </Text>
        <Text className="text-gray-500 dark:text-gray-400 mb-8">
          {user?.primaryEmailAddress?.emailAddress || 'Signed in'}
        </Text>

        <View className="bg-gray-100 dark:bg-gray-800 rounded-lg p-4 mb-6">
          <Text className="text-sm font-semibold text-gray-600 dark:text-gray-300 mb-2">
            Worker API Status
          </Text>
          {loading ? (
            <ActivityIndicator />
          ) : apiError ? (
            <Text className="text-red-500">{apiError}</Text>
          ) : (
            <Text className="text-green-600 dark:text-green-400 font-mono">
              {healthStatus}
            </Text>
          )}
          <TouchableOpacity
            className="mt-3 bg-blue-600 rounded-lg py-2"
            onPress={checkHealth}
          >
            <Text className="text-white text-center font-semibold">
              Test API Connection
            </Text>
          </TouchableOpacity>
        </View>

        <TouchableOpacity
          className="border border-red-300 rounded-lg py-3"
          onPress={handleSignOut}
        >
          <Text className="text-red-600 text-center font-semibold">Sign Out</Text>
        </TouchableOpacity>
      </ScrollView>
    </SafeAreaView>
  )
}
