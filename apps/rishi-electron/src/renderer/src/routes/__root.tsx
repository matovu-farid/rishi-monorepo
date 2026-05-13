import Loader from '../components/Loader'
import { useQuery } from '@tanstack/react-query'
import { createRootRoute, Outlet } from '@tanstack/react-router'
import { useEffect, useMemo, type JSX } from 'react'
import { getBooks } from '@/lib/api'
import { getSyncService } from '@/services'
import { SyncStatusIndicator } from '../components/SyncStatusIndicator'
import { IndexingStatusIndicator } from '../components/IndexingStatusIndicator'
import { NetworkBanner } from '../components/NetworkBanner'
import { WelcomeModal } from '@/components/auth/WelcomeModal'
import { SignInBanner } from '@/components/auth/SignInBanner'
import SignInModal from '@/components/auth/SignInModal'
import { TourProvider } from '@/components/tutorial/TourProvider'
import { ErrorBoundary } from '../components/ErrorBoundary'
import { useHydrateAuth } from '@/hooks/useHydrateAuth'
import { useStartupUpdateCheck } from '@/hooks/useStartupUpdateCheck'
import { useFileOpenHandler } from '@/hooks/useFileOpenHandler'
import { useMenuCommands } from '@/hooks/useMenuCommands'

export const Route = createRootRoute({
  component: () => <RootComponent />
})

function RootComponent(): JSX.Element {
  // Hydrate auth from secure storage + register deep-link listener
  useHydrateAuth()
  useStartupUpdateCheck()
  useFileOpenHandler()
  // Library-level menu handlers. Toggle dark/light by flipping the `dark`
  // class on <html> — matches the menu builder's label-flip pattern. The menu
  // label itself only updates after the renderer reports the new theme via
  // `setMenuContext({ theme })`, but for now this is enough to make the menu
  // command observable in the renderer (and e2e-testable).
  const menuHandlers = useMemo(
    () => ({
      toggleTheme: (): void => {
        document.documentElement.classList.toggle('dark')
      }
    }),
    []
  )
  useMenuCommands(menuHandlers)

  // Initialize desktop sync on app mount
  useEffect(() => {
    const sync = getSyncService()
    sync.start()
    return () => {
      sync.stop()
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
      <div className="fixed bottom-4 right-4 z-50 w-40 flex justify-end">
        <IndexingStatusIndicator />
      </div>
      <NetworkBanner />
    </>
  )
}
