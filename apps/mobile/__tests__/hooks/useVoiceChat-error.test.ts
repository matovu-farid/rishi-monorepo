/**
 * CHT-016 — `useVoiceChat.start` previously surfaced activation failures
 * via `Alert.alert('Voice Chat Error', ...)`, which:
 *   - blocks the entire UI behind a modal
 *   - gives no retry affordance
 *   - has no "Open Settings" path for mic-permission failures
 *
 * The new contract:
 *   - On `svc.activate()` rejection the hook stores the error on its
 *     returned shape (`voiceError`, `isMicPermissionError`) and exposes
 *     a `retryStart()` that re-invokes activate with the same context,
 *     plus a `dismissError()` that clears the local state.
 *   - `Alert.alert` is never called.
 *
 * Consumers render their own snackbar/banner — same pattern the codebase
 * uses elsewhere (`useUndoSnackbar`, `UploadErrorSnackbar`). The chat
 * detail / reader overlay screens read `voiceError` off the hook and
 * mount the banner.
 */

// Stub react-native — `Alert.alert` must remain importable but should
// NEVER fire under the new contract.
const alertMock = jest.fn()
jest.mock('react-native', () => ({
  Alert: { alert: alertMock },
  Platform: { OS: 'ios' },
}))

jest.mock('@rishi/shared/lib/stringToNumberID', () => ({
  stringToNumberID: (s: string) => {
    let h = 0
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0
    return Math.abs(h)
  },
}))

type StateCb = (s: 'idle' | 'connecting' | 'active' | 'paused' | 'error') => void
type ChatCb = (s: 'idle' | 'connecting' | 'thinking' | 'speaking') => void
const stateListeners: StateCb[] = []
const chatListeners: ChatCb[] = []
const mockActivate = jest.fn()
const mockStart = jest.fn()
let currentState: 'idle' | 'connecting' | 'active' | 'paused' | 'error' = 'idle'

function emitState(s: typeof currentState) {
  currentState = s
  stateListeners.slice().forEach((l) => l(s))
}

const fakeService = {
  start: mockStart,
  stop: jest.fn(),
  activate: mockActivate,
  deactivate: jest.fn(),
  getState: () => currentState,
  getError: () => null,
  dismissError: jest.fn(),
  dispose: jest.fn(),
  onStateChange: (cb: StateCb) => {
    stateListeners.push(cb)
    return () => {
      const i = stateListeners.indexOf(cb)
      if (i >= 0) stateListeners.splice(i, 1)
    }
  },
  onChatStatus: (cb: ChatCb) => {
    chatListeners.push(cb)
    return () => {
      const i = chatListeners.indexOf(cb)
      if (i >= 0) chatListeners.splice(i, 1)
    }
  },
  onEndedByAgent: () => () => undefined,
}

jest.mock('@/lib/voice-chat/service', () => ({
  __esModule: true,
  getVoiceChatService: () => fakeService,
  _resetVoiceChatServiceForTests: jest.fn(),
}))

jest.mock('@/lib/voice-chat/sounds', () => ({
  __esModule: true,
  createMobileEffectsPort: jest.fn(() => ({
    playReadyChime: jest.fn(),
    startThinkingSound: jest.fn(),
    stopThinkingSound: jest.fn(),
  })),
  getMobileEffectsPort: jest.fn(() => ({
    playReadyChime: jest.fn(),
    startThinkingSound: jest.fn(),
    stopThinkingSound: jest.fn(),
  })),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { useVoiceChat } from '@/hooks/useVoiceChat'
import type { VoiceChatContext } from '@rishi/shared/voice-chat'

interface HarnessProps {
  bookId: string
  context?: () => VoiceChatContext
  onReady?: (api: ReturnType<typeof useVoiceChat>) => void
}

function Harness(props: HarnessProps) {
  const api = useVoiceChat(props.bookId, { context: props.context })
  React.useEffect(() => {
    props.onReady?.(api)
  })
  return null
}

beforeEach(() => {
  stateListeners.length = 0
  chatListeners.length = 0
  currentState = 'idle'
  mockActivate.mockReset()
  mockStart.mockReset()
  alertMock.mockReset()
})

describe('CHT-016 — voice-chat error surface (no blocking Alert)', () => {
  it('does NOT call Alert.alert when activate() rejects', async () => {
    mockActivate.mockRejectedValueOnce(new Error('connection failed'))

    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })

    expect(alertMock).not.toHaveBeenCalled()
  })

  it('exposes the activation error on the returned hook shape', async () => {
    mockActivate.mockRejectedValueOnce(new Error('connection failed'))

    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })

    expect(api.voiceError).toBe('connection failed')
    expect(api.isMicPermissionError).toBe(false)
  })

  it('classifies mic-permission errors so the consumer can show "Open Settings"', async () => {
    mockActivate.mockRejectedValueOnce(
      new Error('Microphone permission denied'),
    )

    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })

    expect(api.isMicPermissionError).toBe(true)
    expect(api.voiceError).toMatch(/mic|permission/i)
  })

  it('retryStart() re-invokes svc.activate with the same context', async () => {
    const ctx: VoiceChatContext = {
      pageText: 'Chapter 1',
      activeParagraphText: 'p',
    }
    mockActivate
      .mockRejectedValueOnce(new Error('transient'))
      .mockResolvedValueOnce(undefined)

    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          context: () => ctx,
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })
    expect(api.voiceError).toBe('transient')
    expect(mockActivate).toHaveBeenCalledTimes(1)

    await act(async () => {
      await api.retryStart()
    })

    // Retry must have invoked activate a second time with the SAME ctx
    // payload — and clear the error on success.
    expect(mockActivate).toHaveBeenCalledTimes(2)
    expect(mockActivate.mock.calls[1][1]).toEqual(ctx)
    expect(api.voiceError).toBeNull()
  })

  it('dismissError() clears the error without re-activating', async () => {
    mockActivate.mockRejectedValueOnce(new Error('boom'))

    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })
    expect(api.voiceError).toBe('boom')

    act(() => {
      api.dismissError()
    })

    expect(api.voiceError).toBeNull()
    // dismiss must NOT trigger another activation.
    expect(mockActivate).toHaveBeenCalledTimes(1)
  })
})
