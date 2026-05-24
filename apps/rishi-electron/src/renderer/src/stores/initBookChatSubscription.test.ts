import { describe, it, expect, beforeEach, vi } from 'vitest'

// Mock the voice-chat service before importing chatStore so chatStore's
// module-scope getVoiceChatService() call resolves to a spy. Mirrors the
// pattern used in pdfStore.test.ts / chatStore.test.ts.
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

vi.mock('@/services/voice-chat', () => ({
  OfflineError: FakeOfflineError
}))

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))

vi.mock('@/modules/pageCapture', () => ({
  summarizeCurrentPage: vi.fn().mockReturnValue({ equations: 0, figures: 0, images: 0 })
}))

import { useChatStore } from './chatStore'
import { initBookChatSubscription } from './initBookChatSubscription'

describe('initBookChatSubscription', () => {
  beforeEach(() => {
    useChatStore.setState({ isChatting: false, chatStatus: 'idle' })
    vi.clearAllMocks()
  })

  it('calls startChat with the resolved bookId when isChatting flips false → true', async () => {
    const unsub = initBookChatSubscription(() => 99)

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
    expect(fakeVoice.activate).toHaveBeenCalledWith(99, expect.any(Object))

    unsub()
  })

  it('does NOT call startChat when getBookId returns null', async () => {
    const unsub = initBookChatSubscription(() => null)

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).not.toHaveBeenCalled()

    unsub()
  })

  it('does NOT call startChat on the isChatting true → false transition', async () => {
    // Pre-seed isChatting=true so we can observe the true→false edge in
    // isolation. The subscription is registered AFTER the seed so the
    // initial value isn't itself an event.
    useChatStore.setState({ isChatting: true })
    const unsub = initBookChatSubscription(() => 99)

    useChatStore.getState().setIsChatting(false)
    await Promise.resolve()

    expect(fakeVoice.activate).not.toHaveBeenCalled()

    unsub()
  })

  it('returns an unsubscribe that stops further activations', async () => {
    const unsub = initBookChatSubscription(() => 99)
    unsub()

    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).not.toHaveBeenCalled()
  })

  it('resolves getBookId at activation time, not at subscription time', async () => {
    // The closure must be called when isChatting flips, not when init runs —
    // this is what lets each reader view return a value derived from live
    // state (e.g. pdfStore.book.kind === 'pdf').
    let currentId: number | null = null
    const unsub = initBookChatSubscription(() => currentId)

    // First flip: getBookId returns null → no activation.
    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()
    expect(fakeVoice.activate).not.toHaveBeenCalled()

    // Reset isChatting so the next true edge actually fires.
    useChatStore.setState({ isChatting: false })

    // Mutate the closure-bound value, then trigger another true edge.
    currentId = 7
    useChatStore.getState().setIsChatting(true)
    await Promise.resolve()

    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
    expect(fakeVoice.activate).toHaveBeenCalledWith(7, expect.any(Object))

    unsub()
  })
})
