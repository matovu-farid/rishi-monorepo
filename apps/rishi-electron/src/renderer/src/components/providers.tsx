import { QueryClientProvider } from '@tanstack/react-query'
import type { JSX, PropsWithChildren } from 'react'
import { Toaster } from '@/components/ui/sonner'
import { queryClient } from './queryClient'

/**
 * App-wide providers. Authentication is handled out-of-band via the main
 * process (Better Auth + system browser deep-link), so no auth provider
 * is needed in the React tree.
 */
function Providers({ children }: PropsWithChildren): JSX.Element {
  return (
    <QueryClientProvider client={queryClient}>
      {children}
      <Toaster />
    </QueryClientProvider>
  )
}

export default Providers
