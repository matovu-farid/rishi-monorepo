import { Redirect, Tabs } from 'expo-router'
import { useEffect } from 'react'

import { HapticTab } from '@/components/haptic-tab'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { Colors } from '@/constants/theme'
import { useColorScheme } from '@/hooks/use-color-scheme'
import { useAuthStore } from '@/lib/stores/authStore'
import { startSyncTriggers, stopSyncTriggers } from '@/lib/sync/triggers'
import { IS_E2E_TEST } from '@/app/_layout'

export default function TabLayout() {
  const colorScheme = useColorScheme()
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)

  useEffect(() => {
    if (!isAuthenticated) return
    startSyncTriggers()
    return () => {
      stopSyncTriggers()
    }
  }, [isAuthenticated])

  if (!IS_E2E_TEST) {
    if (!authHydrated) return null
    if (!isAuthenticated) return <Redirect href="/(auth)/sign-in" />
  }

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: Colors[colorScheme ?? 'light'].tint,
        headerShown: false,
        tabBarButton: HapticTab,
      }}>
      <Tabs.Screen
        name="index"
        options={{
          title: 'Library',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="book.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="chat"
        options={{
          title: 'Chat',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="message.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="explore"
        options={{
          title: 'Explore',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="paperplane.fill" color={color} />,
        }}
      />
    </Tabs>
  )
}
