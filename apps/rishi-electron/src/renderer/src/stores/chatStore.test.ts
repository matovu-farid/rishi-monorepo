import { describe, it, expect, vi, beforeEach } from 'vitest'

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

vi.mock('@/services/voice-chat', () => ({
  OfflineError: class OfflineError extends Error {
    constructor() {
      super('offline')
      this.name = 'OfflineError'
    }
  }
}))

const playerState = {
  send: vi.fn(),
  currentParagraphs: [] as Array<{ text: string }>,
  activeParagraph: null as { text: string } | null
}

vi.mock('@/stores/playerStore', () => ({
  usePlayerStore: { getState: () => playerState }
}))

vi.mock('@/stores/epubStore', () => ({
  useEpubStore: { getState: () => ({ bookId: '42', bookOutline: null }) }
}))

vi.mock('@/utils/sentry', () => ({ captureError: vi.fn() }))

// Import AFTER the mocks above so chatStore's module-scope getVoiceChatService()
// call resolves to the fakeVoice stub.
import { useChatStore } from './chatStore'

describe('chatStore', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    playerState.currentParagraphs = []
    playerState.activeParagraph = null
    useChatStore.setState({
      isChatting: false,
      chatStatus: 'idle'
    })
  })

  it('starts in idle state', () => {
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('setIsChatting(false) calls voice.deactivate', () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().setIsChatting(false)
    expect(fakeVoice.deactivate).toHaveBeenCalledTimes(1)
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('startChat delegates to voice.activate', async () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().startChat(42)
    // activate is async — await microtask flush
    await Promise.resolve()
    expect(fakeVoice.activate).toHaveBeenCalledWith(42, {
      pageText: expect.any(String),
      outline: undefined,
      activeParagraphText: undefined
    })
  })

  it('startChat forwards the active paragraph text (what TTS is reading)', async () => {
    playerState.currentParagraphs = [{ text: 'Hello.' }, { text: 'World.' }]
    playerState.activeParagraph = { text: 'World.' }
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().startChat(42)
    await Promise.resolve()
    expect(fakeVoice.activate).toHaveBeenCalledWith(
      42,
      expect.objectContaining({ activeParagraphText: 'World.' })
    )
  })

  it('stopConversation resets state and calls deactivate', () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'speaking' })
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(fakeVoice.deactivate).toHaveBeenCalledTimes(1)
  })
})
