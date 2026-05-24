/**
 * CHT-016 (#63) — the `useRealtimeChat` shim must forward the
 * new error-surface fields from `useVoiceChat` so reader screens can
 * mount a snackbar/banner when voice-chat activation fails.
 *
 * Prior to this fix the shim destructured only `{ status, toggle, isActive }`
 * — `voiceError`, `isMicPermissionError`, `retryStart`, and `dismissError`
 * were silently swallowed and reader-screen failures (mic denied, network
 * drop, etc.) regressed from a modal Alert to a silent no-op.
 *
 * The shim now forwards all four fields verbatim from `useVoiceChat`.
 */

jest.mock('react-native', () => ({
  Alert: { alert: jest.fn() },
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
import { useRealtimeChat, type UseRealtimeChatResult } from '@/hooks/useRealtimeChat'

interface HarnessProps {
  bookId: string
  onReady?: (api: UseRealtimeChatResult) => void
}

function Harness(props: HarnessProps) {
  const api = useRealtimeChat(props.bookId)
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
})

describe('CHT-016 (#63) — useRealtimeChat shim forwards voice-error fields', () => {
  it('returns null voiceError and false isMicPermissionError before any failure', () => {
    let api!: UseRealtimeChatResult
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-x',
          onReady: (a) => (api = a),
        }),
      )
    })

    expect(api.voiceError).toBeNull()
    expect(api.isMicPermissionError).toBe(false)
    expect(typeof api.retryStart).toBe('function')
    expect(typeof api.dismissError).toBe('function')
  })

  it('forwards a transient voiceError from useVoiceChat after activate() rejects', async () => {
    mockActivate.mockRejectedValueOnce(new Error('connection failed'))

    let api!: UseRealtimeChatResult
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-x',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      // toggle from idle triggers start → activate, mirroring the
      // reader's `onRealtimePress` path.
      await api.toggle()
    })

    expect(api.voiceError).toBe('connection failed')
    expect(api.isMicPermissionError).toBe(false)
  })

  it('forwards isMicPermissionError=true when the rejection is a mic-permission denial', async () => {
    mockActivate.mockRejectedValueOnce(new Error('Microphone permission denied'))

    let api!: UseRealtimeChatResult
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-x',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.toggle()
    })

    expect(api.isMicPermissionError).toBe(true)
    expect(api.voiceError).toMatch(/mic|permission/i)
  })

  it('retryStart() forwarded by the shim re-invokes svc.activate', async () => {
    mockActivate
      .mockRejectedValueOnce(new Error('transient'))
      .mockResolvedValueOnce(undefined)

    let api!: UseRealtimeChatResult
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-x',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.toggle()
    })
    expect(api.voiceError).toBe('transient')
    expect(mockActivate).toHaveBeenCalledTimes(1)

    await act(async () => {
      await api.retryStart()
    })
    expect(mockActivate).toHaveBeenCalledTimes(2)
    expect(api.voiceError).toBeNull()
  })

  it('dismissError() forwarded by the shim clears the error without re-activating', async () => {
    mockActivate.mockRejectedValueOnce(new Error('boom'))

    let api!: UseRealtimeChatResult
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-x',
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.toggle()
    })
    expect(api.voiceError).toBe('boom')

    act(() => {
      api.dismissError()
    })

    expect(api.voiceError).toBeNull()
    expect(mockActivate).toHaveBeenCalledTimes(1)
  })
})
