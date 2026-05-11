import Loader from '../components/Loader'
import { useQuery } from '@tanstack/react-query'
import { createRootRoute, Outlet } from '@tanstack/react-router'
import { useEffect, type JSX } from 'react'
import { getBooks } from '@/lib/api'
import { initDesktopSync, destroyDesktopSync } from '@/modules/sync-triggers'
import { SyncStatusIndicator } from '../components/SyncStatusIndicator'
import { NetworkBanner } from '../components/NetworkBanner'
import { WelcomeModal } from '@/components/auth/WelcomeModal'
import { SignInBanner } from '@/components/auth/SignInBanner'
import SignInModal from '@/components/auth/SignInModal'
import { TourProvider } from '@/components/tutorial/TourProvider'
import { ErrorBoundary } from '../components/ErrorBoundary'
import { useHydrateAuth } from '@/hooks/useHydrateAuth'
import { useStartupUpdateCheck } from '@/hooks/useStartupUpdateCheck'

export const Route = createRootRoute({
  component: () => <RootComponent />
})

function RootComponent(): JSX.Element {
  // Hydrate auth from secure storage + register deep-link listener
  useHydrateAuth()
  useStartupUpdateCheck()

  // Initialize desktop sync on app mount
  useEffect(() => {
    initDesktopSync()
    return () => {
      destroyDesktopSync()
    }
  }, [])

  const { isPending, error, isError } = useQuery({
    queryKey: ['books'],
    queryFn: async () => {
      return await getBooks()
    },
    retry: 3,
    retryDelay: 1000
  })

  return (
    <>
      {isPending && (
        <div className="fixed inset-0 z-50 w-full h-screen place-items-center grid bg-white">
          <Loader />
        </div>
      )}
      {isError && (
        <div className="fixed inset-0 z-50 w-full h-screen place-items-center grid bg-white">
          {error.message}
        </div>
      )}
      <ErrorBoundary>
        <Outlet />
      </ErrorBoundary>
      <SignInModal />
      <WelcomeModal />
      <SignInBanner />
      <TourProvider />
      <div className="fixed bottom-4 left-4 z-50 w-40">
        <SyncStatusIndicator />
      </div>
      <NetworkBanner />
    </>
  )
}
