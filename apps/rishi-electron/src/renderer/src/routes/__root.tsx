import Loader from '../components/Loader'
import { useQuery } from '@tanstack/react-query'
import { createRootRoute, Outlet, useNavigate } from '@tanstack/react-router'
import { useEffect, useMemo, type JSX, type CSSProperties } from 'react'
import { getBooks } from '@/lib/api'
import { getSyncService, getBookImportService } from '@/services'
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

  // Window-identity guard: keeps each BrowserWindow on the route that matches
  // the identity flag injected at window creation (see preload/windowIdentity).
  //   - library window: any legacy `#/books/N` hash spawns a book window and
  //     resets the library hash to `/`.
  //   - book window: forces the URL to `/books/<bookId>` if it isn't already.
  // Runs once on mount — identity is fixed for the lifetime of the window.
  const navigate = useNavigate()
  useEffect(() => {
    const e = (
      window as unknown as {
        electron: {
          windowIdentity?: { kind: 'library' } | { kind: 'book'; bookId: number }
          openBook(id: number): Promise<void>
        }
      }
    ).electron
    const id = e?.windowIdentity
    const path = window.location.hash.replace(/^#/, '')

    if (id?.kind === 'library') {
      const m = path.match(/^\/books\/(\d+)/)
      if (m) {
        void e.openBook(Number(m[1]))
        void navigate({ to: '/' })
      }
    } else if (id?.kind === 'book') {
      if (!path.startsWith('/books/')) {
        void navigate({ to: '/books/$id', params: { id: String(id.bookId) } })
      }
    }
    // Intentional: identity is set once at window creation; no need to re-run.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])


  // Publish the initial theme to the main process on mount so the View menu's
  // "Switch to Light/Dark Mode" label reflects reality the first time the menu
  // is built for this window.
  useEffect(() => {
    const theme = document.documentElement.classList.contains('dark') ? 'dark' : 'light'
    const e = (
      window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
    ).electron
    e?.setMenuContext({ theme })
  }, [])

  // Library-level menu handlers. Toggle dark/light by flipping the `dark`
  // class on <html>, then publish the new theme so the menu label updates.
  const menuHandlers = useMemo(
    () => ({
      toggleTheme: (): void => {
        document.documentElement.classList.toggle('dark')
        const theme = document.documentElement.classList.contains('dark') ? 'dark' : 'light'
        const e = (
          window as unknown as { electron: { setMenuContext(p: Record<string, unknown>): void } }
        ).electron
        e?.setMenuContext({ theme })
      },
      // Window > Library (⌘1) → focus the library window. Available from any
      // window — the main process either focuses the existing library window
      // or spawns one if it was closed.
      focusLibrary: (): void => {
        const e = (
          window as unknown as { electron: { focusLibrary(): Promise<void> } }
        ).electron
        void e.focusLibrary()
      },
      // File > Open Recent → open the chosen book in its own window. Available
      // from any window (library or book); routes through the same IPC that
      // toolbar / book-cover clicks use.
      openRecent: (arg?: unknown): void => {
        const id = (arg as { bookId?: number } | undefined)?.bookId
        if (typeof id !== 'number') return
        const e = (
          window as unknown as { electron: { openBook(id: number): Promise<void> } }
        ).electron
        void e.openBook(id)
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

  // After a successful import, ask main to rebuild the menu so File > Open
  // Recent reflects the new book without waiting for a window focus event.
  useEffect(() => {
    return getBookImportService().onImportProgress((event) => {
      if (event.kind === 'done') {
        const e = (window as unknown as { electron?: { refreshMenu?(): void } }).electron
        e?.refreshMenu?.()
      }
    })
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
      {/* Transparent top strip that gives the window a draggable handle. With
          titleBarStyle 'hiddenInset' and the native reader toolbar removed,
          book windows have no drag region — content extends edge-to-edge.
          pointerEvents:none lets clicks fall through to content; the
          traffic-light buttons (drawn by macOS above this layer) stay
          clickable as the OS handles them outside the DOM. */}
      <div
        aria-hidden
        style={
          {
            position: 'fixed',
            top: 0,
            left: 0,
            right: 0,
            height: 28,
            zIndex: 9999,
            pointerEvents: 'none',
            WebkitAppRegion: 'drag'
          } as CSSProperties
        }
      />
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
