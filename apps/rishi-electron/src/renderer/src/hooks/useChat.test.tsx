import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

// Mock @/services so we don't construct the real RagService/SyncService.
vi.mock('@/services', () => ({
  getRagService: () => ({
    searchSemantic: vi.fn().mockResolvedValue([])
  }),
  getSyncService: () => ({
    triggerWrite: vi.fn()
  })
}))

// Mock auth token helper so sendMessage doesn't throw on the auth check
// (only relevant for tests that exercise the post-init path).
vi.mock('@/modules/auth', () => ({
  getAuthToken: vi.fn().mockResolvedValue('test-token')
}))

import { useChat } from './useChat'

describe('useChat — readiness gate (CHT-012)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(window.electron.booksGetSyncId).mockResolvedValue('sync-id-1')
    vi.mocked(window.electron.conversationsFindForBook).mockResolvedValue(null)
    vi.mocked(window.electron.conversationsCreate).mockResolvedValue(undefined)
    vi.mocked(window.electron.messagesList).mockResolvedValue([])
  })

  it('exposes isReady=false while conversation is being created', () => {
    // Hold conversationsFindForBook un-resolved so init never completes
    // synchronously.
    vi.mocked(window.electron.conversationsFindForBook).mockReturnValue(new Promise(() => {}))

    const { result } = renderHook(() => useChat(1, 'sync-id-1', 'Book Title'))

    // Before init resolves, the conversation isn't ready — input must be gated.
    expect(result.current.isReady).toBe(false)
    expect(result.current.conversationId).toBeNull()
  })

  it('flips isReady=true once conversationId resolves', async () => {
    const { result } = renderHook(() => useChat(1, 'sync-id-1', 'Book Title'))

    await waitFor(() => {
      expect(result.current.conversationId).not.toBeNull()
    })

    expect(result.current.isReady).toBe(true)
  })

  it('sendMessage is a no-op before conversation is ready (no orphan messages)', async () => {
    // Keep init pending so conversationId stays null.
    vi.mocked(window.electron.conversationsFindForBook).mockReturnValue(new Promise(() => {}))

    const { result } = renderHook(() => useChat(1, 'sync-id-1', 'Book Title'))

    await act(async () => {
      await result.current.sendMessage('hello before ready')
    })

    // No user message should have been persisted.
    expect(window.electron.messagesCreate).not.toHaveBeenCalled()
    // And no optimistic message should appear in state.
    expect(result.current.messages).toEqual([])
  })

  it('isReady flips back to false when bookId changes (re-init)', async () => {
    const { result, rerender } = renderHook(({ bookId }) => useChat(bookId, 'sync-id-1', 'Title'), {
      initialProps: { bookId: 1 }
    })

    await waitFor(() => {
      expect(result.current.isReady).toBe(true)
    })

    // Hold the second init pending so we can observe the not-ready window.
    vi.mocked(window.electron.conversationsFindForBook).mockReturnValue(new Promise(() => {}))
    rerender({ bookId: 2 })

    expect(result.current.isReady).toBe(false)
  })
})
