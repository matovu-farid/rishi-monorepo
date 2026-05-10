import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

const mockMute = vi.fn()
const mockInterrupt = vi.fn()
const mockClose = vi.fn()
const mockUpdateAgent = vi.fn().mockResolvedValue(undefined)
const mockConnect = vi.fn().mockResolvedValue(undefined)
const mockSessionOn = vi.fn()
const mockSessionOff = vi.fn()

vi.mock('@openai/agents/realtime', () => ({
  RealtimeSession: vi.fn().mockImplementation(function () {
    return {
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent,
      connect: mockConnect,
      on: mockSessionOn,
      off: mockSessionOff
    }
  }),
  RealtimeAgent: vi.fn(),
  tool: vi.fn()
}))

vi.mock('@/modules/realtime', () => ({
  getOrFetchKey: vi.fn().mockResolvedValue('test-key'),
  prefetchRealtimeKey: vi.fn()
}))

vi.mock('@/modules/buildRealtimeAgent', () => ({
  buildRealtimeAgent: vi.fn().mockReturnValue({ /* fake agent */ })
}))

vi.mock('@/utils/sentry', () => ({
  captureError: vi.fn()
}))

// Stub out the WebRTC transport — we test the orchestration, not the transport itself
vi.mock('@openai/agents-realtime', async () => {
  const actual = await vi.importActual<object>('@openai/agents-realtime')
  return {
    ...actual,
    OpenAIRealtimeWebRTC: vi.fn().mockImplementation(function () {
      return {}
    })
  }
})

vi.mock('@/modules/readyChime', () => ({
  playReadyChime: vi.fn()
}))

vi.mock('@/modules/thinkingSound', () => ({
  startThinkingSound: vi.fn(),
  stopThinkingSound: vi.fn()
}))

vi.mock('@/stores/chatStore', () => ({
  useChatStore: {
    getState: vi.fn().mockReturnValue({ chatStatus: 'connecting' })
  }
}))

import { voiceChatService } from './voiceChatService'

describe('voiceChatService', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers()
    voiceChatService._resetForTests()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts in idle state', () => {
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('deactivate from idle is a no-op', () => {
    voiceChatService.deactivate()
    expect(voiceChatService.getState()).toBe('idle')
    expect(mockMute).not.toHaveBeenCalled()
  })

  it('schedules idle timeout on deactivate when active', async () => {
    // Set internal state to a "fake-connected" state via test hook
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose
    } as never, 1)

    voiceChatService.deactivate()
    expect(mockInterrupt).toHaveBeenCalledTimes(1)
    expect(mockMute).toHaveBeenCalledWith(true)
    expect(voiceChatService.getState()).toBe('paused')

    // Idle timer not yet fired
    expect(mockClose).not.toHaveBeenCalled()

    // Advance past 15 minutes
    vi.advanceTimersByTime(15 * 60 * 1000 + 100)
    expect(mockClose).toHaveBeenCalledTimes(1)
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('cancels idle timer when reactivated within timeout', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    voiceChatService.deactivate()
    vi.advanceTimersByTime(10 * 60 * 1000)

    await voiceChatService.activate(1, 'fresh page text')
    expect(mockMute).toHaveBeenLastCalledWith(false)
    expect(mockUpdateAgent).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(10 * 60 * 1000)
    // Still active — close should not have been called
    expect(mockClose).not.toHaveBeenCalled()
  })

  it('disposes existing session when activating with a different bookId', async () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose,
      updateAgent: mockUpdateAgent
    } as never, 1)

    // Note: activate(2, ...) should detect bookId mismatch and dispose old session.
    // It will then try to create a new one via the (stubbed) transport — that
    // path is exercised more fully in Task 3 tests. Here we only verify the
    // dispose-on-mismatch happens.
    await voiceChatService.activate(2, 'text for book 2').catch(() => {
      /* expected: new-session path not fully wired in this task */
    })
    expect(mockClose).toHaveBeenCalledTimes(1)
  })

  it('dispose() closes session and returns to idle', () => {
    voiceChatService._setSessionForTests({
      mute: mockMute,
      interrupt: mockInterrupt,
      close: mockClose
    } as never, 1)

    voiceChatService.dispose()
    expect(mockClose).toHaveBeenCalledTimes(1)
    expect(voiceChatService.getState()).toBe('idle')
  })

  it('prewarmKey delegates to realtime module', async () => {
    const { prefetchRealtimeKey } = await import('@/modules/realtime')
    voiceChatService.prewarmKey()
    expect(prefetchRealtimeKey).toHaveBeenCalledTimes(1)
  })

  it('deactivate falls back to dispose when interrupt throws', () => {
    const throwingInterrupt = vi.fn(() => {
      throw new Error('interrupt failed')
    })
    voiceChatService._setSessionForTests({
      interrupt: throwingInterrupt,
      mute: mockMute,
      close: mockClose
    } as never, 1)

    voiceChatService.deactivate()

    expect(throwingInterrupt).toHaveBeenCalledTimes(1)
    expect(mockClose).toHaveBeenCalledTimes(1) // dispose() ran
    expect(voiceChatService.getState()).toBe('idle') // not 'paused'
  })
})

describe('voiceChatService cold path', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    voiceChatService._resetForTests()

    // Stub getUserMedia globally
    const fakeStream = {
      getTracks: () => [{ stop: vi.fn() }]
    }
    ;(global.navigator as unknown as { mediaDevices: { getUserMedia: typeof vi.fn } }).mediaDevices = {
      getUserMedia: vi.fn().mockResolvedValue(fakeStream)
    }
  })

  it('cold activate: getUserMedia + transport + session.connect, then unmute', async () => {
    const { OpenAIRealtimeWebRTC } = await import('@openai/agents-realtime')

    await voiceChatService.activate(7, 'fresh text')

    expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledWith({ audio: true })
    expect(OpenAIRealtimeWebRTC).toHaveBeenCalledTimes(1)
    expect(mockConnect).toHaveBeenCalledWith({ apiKey: 'test-key' })
    expect(mockMute).toHaveBeenCalledWith(false)
    expect(voiceChatService.getState()).toBe('active')
  })

  it('cold activate caches mediaStream and audio element across activate/deactivate cycles', async () => {
    await voiceChatService.activate(7, 'text 1')
    const firstGetUserMediaCount = (navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>)
      .mock.calls.length

    voiceChatService.deactivate()
    await voiceChatService.activate(7, 'text 2')

    // No new mic prompt — same stream reused
    expect(
      (navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mock.calls.length
    ).toBe(firstGetUserMediaCount)
  })

  it('disposes mediaStream tracks on dispose()', async () => {
    const stopSpy = vi.fn()
    ;(navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      getTracks: () => [{ stop: stopSpy }]
    })

    await voiceChatService.activate(7, 'x')
    voiceChatService.dispose()
    expect(stopSpy).toHaveBeenCalledTimes(1)
  })

  it('removes session event listeners on dispose', async () => {
    await voiceChatService.activate(7, 'x')
    // 7 .on() calls during cold-path activation
    expect(mockSessionOn).toHaveBeenCalledTimes(7)

    voiceChatService.dispose()
    // 7 .off() calls during dispose
    expect(mockSessionOff).toHaveBeenCalledTimes(7)
  })
})
