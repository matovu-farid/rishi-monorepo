import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useChatStore } from './chatStore'

const {
  mockActivate,
  mockDeactivate,
  mockDispose,
  mockSetListeners,
  mockGetState
} = vi.hoisted(() => ({
  mockActivate: vi.fn().mockResolvedValue(undefined),
  mockDeactivate: vi.fn(),
  mockDispose: vi.fn(),
  mockSetListeners: vi.fn(),
  mockGetState: vi.fn().mockReturnValue('idle')
}))

vi.mock('@/modules/voiceChatService', () => ({
  voiceChatService: {
    activate: mockActivate,
    deactivate: mockDeactivate,
    dispose: mockDispose,
    setListeners: mockSetListeners,
    getState: mockGetState,
    prewarmKey: vi.fn()
  }
}))

vi.mock('@/stores/playerStore', () => ({
  usePlayerStore: { getState: () => ({ send: vi.fn(), currentParagraphs: [] }) }
}))

vi.mock('@/stores/epubStore', () => ({
  useEpubStore: { getState: () => ({ bookId: '42', bookOutline: null }) }
}))

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))

describe('chatStore', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    useChatStore.setState({
      isChatting: false,
      chatStatus: 'idle',
      _chatGeneration: 0,
      _isStarting: false
    })
  })

  it('starts in idle state', () => {
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('setIsChatting(false) calls voiceChatService.deactivate', () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().setIsChatting(false)
    expect(mockDeactivate).toHaveBeenCalledTimes(1)
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('startChat delegates to voiceChatService.activate', async () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().startChat(42)
    // activate is async — await microtask flush
    await Promise.resolve()
    expect(mockActivate).toHaveBeenCalledWith(42, {
      pageText: expect.any(String),
      outline: undefined
    })
  })

  it('stopConversation resets state and calls deactivate', () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'speaking' })
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(mockDeactivate).toHaveBeenCalledTimes(1)
  })

  it('prevents concurrent startChat calls', () => {
    useChatStore.setState({ _isStarting: true, isChatting: true })
    useChatStore.getState().startChat(1)
    expect(mockActivate).not.toHaveBeenCalled()
  })
})
