import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useEffect, useRef } from 'react'

// Mock the voice-chat service so chatStore.startChat → voice.activate is a
// spy we can assert on. Mirrors pdfStore.test.ts / chatStore.test.ts setup.
const { fakeVoice } = vi.hoisted(() => ({
  fakeVoice: {
    start: vi.fn(),
    stop: vi.fn(),
    activate: vi.fn().mockResolvedValue(undefined),
    preconnect: vi.fn().mockResolvedValue(undefined),
    deactivate: vi.fn(),
    dispose: vi.fn(),
    prewarmKey: vi.fn(),
    getState: vi.fn().mockReturnValue('idle' as const),
    getError: vi.fn().mockReturnValue(null),
    dismissError: vi.fn(),
    onStateChange: vi.fn().mockReturnValue(() => {}),
    onChatStatus: vi.fn().mockReturnValue(() => {}),
    onEndedByAgent: vi.fn().mockReturnValue(() => {})
  }
}))

vi.mock('@/services', () => ({
  getVoiceChatService: () => fakeVoice
}))

const { FakeOfflineError } = vi.hoisted(() => ({
  FakeOfflineError: class OfflineError extends Error {
    constructor() {
      super('offline')
      this.name = 'OfflineError'
    }
  }
}))
vi.mock('@rishi/shared/voice-chat', () => ({ OfflineError: FakeOfflineError }))
vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))
vi.mock('@/modules/pageCapture', () => ({
  summarizeCurrentPage: vi.fn().mockReturnValue({ equations: 0, figures: 0, images: 0 })
}))

import type { Book } from '@/lib/api'
import { useChatStore } from '@/stores/chatStore'
import { initBookChatSubscription } from '@/stores/initBookChatSubscription'

const makeBook = (overrides: Partial<Book> = {}): Book => ({
  id: 42,
  kind: 'mobi',
  cover: [],
  title: 'Test',
  author: 'Test Author',
  publisher: '',
  filepath: '/tmp/test.mobi',
  location: '0:0',
  coverKind: '',
  version: 0,
  format: 'mobi',
  syncVersion: 0,
  isDirty: 0,
  isDeleted: 0,
  ...overrides
})

/**
 * Mirrors the exact subscription-lifecycle pattern Azw3View installs at
 * mount time (and that EpubView already uses at EpubView.tsx:867-875).
 * Kept as a local helper here so the test exercises the same useEffect +
 * useRef cleanup wiring without dragging in the full Azw3View module
 * graph (foliate-js parser, react-query, navigation history, etc).
 *
 * If Azw3View's wiring diverges from this shape, the integration assertion
 * "calls startChat exactly once when isChatting flips" must still hold —
 * that's the contract enforced here.
 */
function useBookChatActivationLikeAzw3View(book: Book): void {
  const unsubsRef = useRef<(() => void)[]>([])
  useEffect(() => {
    unsubsRef.current = [initBookChatSubscription(() => book.id)]
    return () => {
      unsubsRef.current.forEach((fn) => fn())
      unsubsRef.current = []
    }
  }, [book.id])
}

describe('Azw3View voice chat activation (#237)', () => {
  beforeEach(() => {
    useChatStore.setState({ isChatting: false, chatStatus: 'idle' })
    vi.clearAllMocks()
  })

  it('calls startChat with the MOBI book id when isChatting flips true', async () => {
    const book = makeBook({ id: 101, kind: 'mobi' })
    renderHook(() => useBookChatActivationLikeAzw3View(book))

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
    expect(fakeVoice.activate).toHaveBeenCalledWith(101, expect.any(Object))
  })

  it('calls startChat with the AZW3 book id when isChatting flips true', async () => {
    const book = makeBook({ id: 202, kind: 'azw3', filepath: '/tmp/test.azw3', format: 'azw3' })
    renderHook(() => useBookChatActivationLikeAzw3View(book))

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
    expect(fakeVoice.activate).toHaveBeenCalledWith(202, expect.any(Object))
  })

  it('unsubscribes on unmount so a later isChatting flip is ignored', async () => {
    const book = makeBook({ id: 303, kind: 'mobi' })
    const { unmount } = renderHook(() => useBookChatActivationLikeAzw3View(book))

    unmount()

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).not.toHaveBeenCalled()
  })

  it('does not double-fire on a remount with the same book id', async () => {
    const book = makeBook({ id: 404, kind: 'azw3' })
    const { unmount } = renderHook(() => useBookChatActivationLikeAzw3View(book))
    unmount()
    renderHook(() => useBookChatActivationLikeAzw3View(book))

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    // Exactly one activation per isChatting false→true edge. If the old
    // subscription leaked across the unmount, this would be 2.
    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
  })
})
