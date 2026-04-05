import { useAuth } from '@clerk/expo'
import { Redirect, Tabs } from 'expo-router'
import { useEffect } from 'react'

import { HapticTab } from '@/components/haptic-tab'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { Colors } from '@/constants/theme'
import { useColorScheme } from '@/hooks/use-color-scheme'
import { initApiClient } from '@/lib/api'

export default function TabLayout() {
  const colorScheme = useColorScheme()
  const { isSignedIn, isLoaded, getToken } = useAuth()

  useEffect(() => {
    if (isSignedIn) {
      initApiClient(getToken)
    }
  }, [isSignedIn, getToken])

  if (!isLoaded) return null
  if (!isSignedIn) return <Redirect href="/(auth)/sign-in" />

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
        name="explore"
        options={{
          title: 'Explore',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="paperplane.fill" color={color} />,
        }}
      />
    </Tabs>
  )
}
