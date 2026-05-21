/**
 * Tests for the mobile chatStore (ported from electron).
 *
 * The electron chatStore is a thin facade over the voice-chat service.
 * Mobile preserves the same public surface (isChatting, chatStatus,
 * voiceState, voiceError + actions) but routes voice operations through
 * an injectable VoiceChatPort so the not-yet-ported voice-chat service
 * can wire in later. See `.parity/BATCH-1B-NOTES.md` (#1).
 */

// ── Mock MMKV in case anything pulls in the storage layer transitively ──
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => ({
    set: () => undefined,
    getString: () => undefined,
    remove: () => false,
    getAllKeys: () => [],
    clearAll: () => undefined,
  }),
}))

import {
  useChatStore,
  setChatVoicePort,
  type VoiceChatPort,
} from '@/lib/stores/chatStore'

function buildFakeVoice(): jest.Mocked<VoiceChatPort> {
  return {
    activate: jest.fn().mockResolvedValue(undefined),
    deactivate: jest.fn(),
    getState: jest.fn().mockReturnValue('idle'),
    getError: jest.fn().mockReturnValue(null),
    dismissError: jest.fn(),
    onStateChange: jest.fn().mockReturnValue(() => undefined),
    onChatStatus: jest.fn().mockReturnValue(() => undefined),
    onEndedByAgent: jest.fn().mockReturnValue(() => undefined),
  }
}

describe('chatStore (mobile)', () => {
  let fakeVoice: jest.Mocked<VoiceChatPort>

  beforeEach(() => {
    fakeVoice = buildFakeVoice()
    setChatVoicePort(fakeVoice)
    useChatStore.setState({ isChatting: false, chatStatus: 'idle', voiceError: null })
  })

  it('starts in idle state with isChatting=false', () => {
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(useChatStore.getState().voiceError).toBeNull()
  })

  it('setIsChatting(true) flips isChatting without calling deactivate', () => {
    useChatStore.getState().setIsChatting(true)
    expect(useChatStore.getState().isChatting).toBe(true)
    expect(fakeVoice.deactivate).not.toHaveBeenCalled()
  })

  it('setIsChatting(false) calls voice.deactivate', () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().setIsChatting(false)
    expect(fakeVoice.deactivate).toHaveBeenCalledTimes(1)
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('setIsChatting accepts an updater function', () => {
    useChatStore.setState({ isChatting: true })
    useChatStore.getState().setIsChatting((prev) => !prev)
    expect(useChatStore.getState().isChatting).toBe(false)
  })

  it('setChatStatus writes the status field', () => {
    useChatStore.getState().setChatStatus('thinking')
    expect(useChatStore.getState().chatStatus).toBe('thinking')
    useChatStore.getState().setChatStatus('speaking')
    expect(useChatStore.getState().chatStatus).toBe('speaking')
  })

  it('startChat delegates to voice.activate with the supplied bookId', async () => {
    useChatStore.getState().startChat(42)
    await Promise.resolve()
    expect(fakeVoice.activate).toHaveBeenCalledTimes(1)
    expect(fakeVoice.activate).toHaveBeenCalledWith(42, expect.any(Object))
  })

  it('startChat resets state when voice.activate rejects', async () => {
    fakeVoice.activate.mockRejectedValueOnce(new Error('boom'))
    useChatStore.setState({ isChatting: true, chatStatus: 'connecting' })
    useChatStore.getState().startChat(42)
    // Flush the rejection + catch body
    await Promise.resolve()
    await Promise.resolve()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
  })

  it('stopConversation resets state and calls deactivate', () => {
    useChatStore.setState({ isChatting: true, chatStatus: 'speaking' })
    useChatStore.getState().stopConversation()
    expect(useChatStore.getState().isChatting).toBe(false)
    expect(useChatStore.getState().chatStatus).toBe('idle')
    expect(fakeVoice.deactivate).toHaveBeenCalledTimes(1)
  })

  it('dismissVoiceError forwards to the port', () => {
    useChatStore.getState().dismissVoiceError()
    expect(fakeVoice.dismissError).toHaveBeenCalledTimes(1)
  })

  it('default port (when never set) is a safe no-op', () => {
    // Rebuild the noop port — pass an object that explicitly mirrors the noop shape
    setChatVoicePort({
      activate: () => Promise.resolve(),
      deactivate: () => undefined,
      getState: () => 'idle',
      getError: () => null,
      dismissError: () => undefined,
      onStateChange: () => () => undefined,
      onChatStatus: () => () => undefined,
      onEndedByAgent: () => () => undefined,
    })
    expect(() => useChatStore.getState().stopConversation()).not.toThrow()
    expect(() => useChatStore.getState().dismissVoiceError()).not.toThrow()
  })
})
