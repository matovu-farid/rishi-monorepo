import { describe, it, expect, beforeEach, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

// Mock @/services so we can capture the push-on-sign-in trigger without
// constructing the real SyncService (which would spin up listeners).
const triggerWrite = vi.fn()
vi.mock('@/services', () => ({
  getSyncService: () => ({
    triggerWrite,
    start: vi.fn(),
    stop: vi.fn(),
    getStatus: () => ({ status: 'not-synced', lastSyncAt: null }),
    onStatusChange: () => () => {}
  })
}))

import { useHydrateAuth } from './useHydrateAuth'
import { useAuthStore } from '@/stores/authStore'

describe('useHydrateAuth — push-on-sign-in', () => {
  beforeEach(() => {
    triggerWrite.mockClear()
    // Reset to signed-out
    useAuthStore.setState({
      user: null,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      signInOpen: false
    })
    vi.mocked(window.api.auth.getSession).mockResolvedValue(null)
  })

  it('calls SyncService.triggerWrite() when onSessionChange flips to a signed-in user', async () => {
    // Capture the callback so we can simulate the main-process broadcast.
    let sessionCallback: ((user: { id: string; email: string } | null) => void) | undefined
    vi.mocked(window.api.auth.onSessionChange).mockImplementation((cb) => {
      sessionCallback = cb
      return () => {}
    })

    renderHook(() => useHydrateAuth())

    // Wait for the initial getSession() to resolve so lastUserId is null.
    await waitFor(() => {
      expect(useAuthStore.getState().authHydrated).toBe(true)
    })
    expect(triggerWrite).not.toHaveBeenCalled()

    // Simulate sign-in.
    sessionCallback?.({ id: 'user-123', email: 'a@b.com' })

    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('does not re-trigger if the same user fires onSessionChange again (token refresh)', async () => {
    let sessionCallback: ((user: { id: string; email: string } | null) => void) | undefined
    vi.mocked(window.api.auth.onSessionChange).mockImplementation((cb) => {
      sessionCallback = cb
      return () => {}
    })

    renderHook(() => useHydrateAuth())
    await waitFor(() => {
      expect(useAuthStore.getState().authHydrated).toBe(true)
    })

    sessionCallback?.({ id: 'user-123', email: 'a@b.com' })
    sessionCallback?.({ id: 'user-123', email: 'a@b.com' })

    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('does not trigger on sign-out (user becomes null)', async () => {
    let sessionCallback: ((user: { id: string; email: string } | null) => void) | undefined
    vi.mocked(window.api.auth.onSessionChange).mockImplementation((cb) => {
      sessionCallback = cb
      return () => {}
    })
    vi.mocked(window.api.auth.getSession).mockResolvedValue({ id: 'u1', email: 'a@b.com' })

    renderHook(() => useHydrateAuth())
    await waitFor(() => {
      expect(useAuthStore.getState().authHydrated).toBe(true)
    })

    sessionCallback?.(null)
    expect(triggerWrite).not.toHaveBeenCalled()
  })

  it('swallows triggerWrite() errors so sign-in UX is never blocked', async () => {
    let sessionCallback: ((user: { id: string; email: string } | null) => void) | undefined
    vi.mocked(window.api.auth.onSessionChange).mockImplementation((cb) => {
      sessionCallback = cb
      return () => {}
    })
    triggerWrite.mockImplementationOnce(() => {
      throw new Error('sync engine not started')
    })

    renderHook(() => useHydrateAuth())
    await waitFor(() => {
      expect(useAuthStore.getState().authHydrated).toBe(true)
    })

    expect(() => sessionCallback?.({ id: 'u', email: 'a@b.com' })).not.toThrow()
  })
})
