import { QueryClientProvider } from '@tanstack/react-query'
import type { JSX, PropsWithChildren } from 'react'
import { Toaster } from '@/components/ui/sonner'
import { queryClient } from './queryClient'
import { SessionMachineProvider } from '@/hooks/useSessionMachine'
import { SharingSessionOverlay } from '@/components/sharing/SharingSessionOverlay'
import { BillingInactiveModal } from '@/components/billing/BillingInactiveModal'

/**
 * App-wide providers. Authentication is handled out-of-band via the main
 * process (Better Auth + system browser deep-link), so no auth provider
 * is needed in the React tree.
 *
 * `SessionMachineProvider` wraps the tree so every sharing consumer
 * (`SessionEntryButton`, `SharingSessionOverlay`) shares a single
 * sessionMachine actor — without it, each `useSessionMachine` caller
 * would spawn its own actor and the overlay would render a stale stub.
 */
function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <QueryClientProvider client={queryClient}>
      <SessionMachineProvider>
        {children}
        <SharingSessionOverlay />
        <BillingInactiveModal />
        <Toaster />
      </SessionMachineProvider>
    </QueryClientProvider>
  )
}

export default Providers
