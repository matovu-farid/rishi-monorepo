import { describe, it, expect, afterEach } from 'vitest'
import { render, screen, act, cleanup } from '@testing-library/react'
import type { JSX } from 'react'
import { useIsOnline } from './useIsOnline'

function Probe(): JSX.Element {
  const online = useIsOnline()
  return <span data-testid="status">{online ? 'on' : 'off'}</span>
}

afterEach(() => {
  cleanup()
})

describe('useIsOnline', () => {
  it('returns the current online state on first render', async () => {
    const { setTestConnectivityService } = await import('@/services')
    const listeners = new Set<(b: boolean) => void>()
    setTestConnectivityService({
      isOnline: () => true,
      subscribe: (l) => {
        listeners.add(l)
        return () => listeners.delete(l)
      },
      start: () => {},
      stop: () => {}
    })

    render(<Probe />)
    expect(screen.getByTestId('status').textContent).toBe('on')

    setTestConnectivityService(null)
  })

  it('updates when the service notifies a transition', async () => {
    const { setTestConnectivityService } = await import('@/services')
    let current = true
    const listeners = new Set<(b: boolean) => void>()
    setTestConnectivityService({
      isOnline: () => current,
      subscribe: (l) => {
        listeners.add(l)
        return () => listeners.delete(l)
      },
      start: () => {},
      stop: () => {}
    })

    render(<Probe />)
    expect(screen.getByTestId('status').textContent).toBe('on')

    act(() => {
      current = false
      for (const l of listeners) l(false)
    })

    expect(screen.getByTestId('status').textContent).toBe('off')

    setTestConnectivityService(null)
  })
})
