import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useChatStore } from './chatStore'
import { startRealtime } from '@/modules/realtime'

// Mock realtime module
vi.mock('@/modules/realtime', () => ({
  startRealtime: vi.fn().mockResolvedValue({ close: vi.fn() }),
  sessionCleanupMap: new WeakMap()
}))

vi.mock('@/modules/thinkingSound', () => ({
  stopThinkingSound: vi.fn()
}))

describe('chatStore', () => {
  beforeEach(() => {
    useChatStore.setState({
      isChatting: false,
      realtimeSession: null,
      chatStatus: 'idle',
      _chatGeneration: 0,
      _isStarting: false
    })
    vi.clearAllMocks()
  })

  it('should start in idle state', () => {
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('should set chat status', () => {
    useChatStore.getState().setChatStatus('thinking')
    expect(useChatStore.getState().chatStatus).toBe('thinking')
  })

  it('stopConversation resets state', () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'speaking' })
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().realtimeSession).toBeNull()
  })

  it('stopConversation increments generation to discard in-flight sessions', () => {
    const gen = useChatStore.getState()._chatGeneration
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState()._chatGeneration).toBe(gen + 1)
  })

  it('prevents concurrent startChat calls', () => {
    useChatStore.setState({ _isStarting: true, isChatting: true })
    useChatStore.getState().startChat(1)
    // _isStarting is true, so startRealtime should not have been called again
    expect(startRealtime).not.toHaveBeenCalled()
  })
})
