import { Redirect, Tabs } from 'expo-router'
import { useEffect } from 'react'

import { HapticTab } from '@/components/haptic-tab'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { Colors } from '@/constants/theme'
import { useColorScheme } from '@/hooks/use-color-scheme'
import { useAuthStore } from '@/lib/stores/authStore'
import { useTutorialStore } from '@/lib/stores/tutorialStore'
import { startSyncTriggers, stopSyncTriggers } from '@/lib/sync/triggers'
import { IS_E2E_TEST } from '@/app/_layout'
import { TourProvider } from '@/components/onboarding/TourProvider'
import { UploadErrorSnackbar } from '@/components/UploadErrorSnackbar'
import { GlobalMiniPlayer } from '@/components/player/GlobalMiniPlayer'

export default function TabLayout() {
  const colorScheme = useColorScheme()
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)
  const authHydrated = useAuthStore((s) => s.authHydrated)
  const tourCompleted = useTutorialStore((s) => s.tourCompleted)
  const startTour = useTutorialStore((s) => s.startTour)

  useEffect(() => {
    if (!isAuthenticated) return
    startSyncTriggers()
    return () => {
      stopSyncTriggers()
    }
  }, [isAuthenticated])

  // First-launch tour kick-off (G28). `startTour` is a no-op when
  // the tour has already been completed, so this is safe to call
  // eagerly when the user signs in.
  useEffect(() => {
    if (!isAuthenticated) return
    if (tourCompleted) return
    const id = setTimeout(() => {
      startTour()
    }, 600)
    return () => {
      clearTimeout(id)
    }
  }, [isAuthenticated, tourCompleted, startTour])

  if (!IS_E2E_TEST) {
    if (!authHydrated) return null
    if (!isAuthenticated) return <Redirect href="/(auth)/sign-in" />
  }

  return (
    <>
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: Colors[colorScheme ?? 'light'].tint,
        headerShown: false,
        tabBarButton: HapticTab,
      }}
      // GlobalMiniPlayer must live INSIDE the bottom-tab navigator's
      // screen context so `useBottomTabBarHeight()` resolves (the hook
      // throws when called outside a tab screen). screenLayout wraps
      // each tab screen — rendering it here also implicitly scopes the
      // player to tab routes only, so stack routes like /reader/[id]
      // and /chat/[bookId] (which live outside `(tabs)/`) never see it.
      // See: components/player/GlobalMiniPlayer.tsx for P0-Q/P0-R notes.
      screenLayout={({ children }) => (
        <>
          {children}
          <GlobalMiniPlayer />
        </>
      )}>
      <Tabs.Screen
        name="index"
        options={{
          title: 'Library',
          tabBarButtonTestID: 'tab-library',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="book.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="chat"
        options={{
          title: 'Chat',
          tabBarButtonTestID: 'tab-chat',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="message.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="settings/index"
        options={{
          title: 'Settings',
          tabBarButtonTestID: 'tab-settings',
          tabBarIcon: ({ color }) => <IconSymbol size={28} name="gearshape.fill" color={color} />,
        }}
      />
      {/* Boilerplate "explore" tab from the Expo template is hidden
          but kept in the router tree so deep-links/cold-starts don't
          404 if any persisted state references it. */}
      <Tabs.Screen
        name="explore"
        options={{
          href: null,
        }}
      />
    </Tabs>
    <TourProvider />
    <UploadErrorSnackbar />
    </>
  )
}
