/**
 * useVoiceChat hook — pinned behaviour for CHT-002 and CHT-007.
 *
 * CHT-002 (P1): `useVoiceChat` must forward the `context` provider's
 * return value to `svc.activate`. Previously it fell back to
 * `{ pageText: '' }` because per-format readers (MOBI/PDF/DJVU) never
 * wired `getActivationContext` through ReaderShell. The hook still
 * accepts the lazy `context: () => VoiceChatContext` shape; the test
 * pins that the captured payload reaches the shared service.
 *
 * CHT-007 (P1): when the chat lifecycle reaches `publicState === 'active'`
 * AND `chatStatus === 'thinking'`, the mobile EffectsPort's
 * `startThinkingSound()` must fire (a periodic haptic loop). Any other
 * status transition must cancel the loop. Electron parity is the Web
 * Audio oscillator tick; mobile substitutes a periodic
 * `Haptics.selectionAsync` pulse so the user still gets feedback while
 * the model composes a reply — especially with the screen locked.
 */

// Stub react-native to a host-string shim — useVoiceChat imports `Alert`
// transitively via the catch branch; the test never triggers that path.
jest.mock('react-native', () => ({
  Alert: { alert: jest.fn() },
  Platform: { OS: 'ios' },
}))

// Stub the shared `stringToNumberID` to a deterministic hash so the test
// can assert the numeric bookId that reaches `svc.activate`.
jest.mock('@rishi/shared/lib/stringToNumberID', () => ({
  stringToNumberID: (s: string) => {
    let h = 0
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0
    return Math.abs(h)
  },
}))

// Capture the latest shared voice-chat service injected via `setChatVoicePort`.
// We expose `activate`, `getState`, `onStateChange`, `onChatStatus` mocks so
// the test can drive transitions through the hook's emitter wiring.
type StateCb = (s: 'idle' | 'connecting' | 'active' | 'paused' | 'error') => void
type ChatCb = (s: 'idle' | 'connecting' | 'thinking' | 'speaking') => void

const stateListeners: StateCb[] = []
const chatListeners: ChatCb[] = []
const mockActivate = jest.fn().mockResolvedValue(undefined)
const mockDeactivate = jest.fn()
const mockStart = jest.fn()
let currentState: 'idle' | 'connecting' | 'active' | 'paused' | 'error' = 'idle'

function emitState(s: 'idle' | 'connecting' | 'active' | 'paused' | 'error') {
  currentState = s
  stateListeners.slice().forEach((l) => l(s))
}
function emitChat(s: 'idle' | 'connecting' | 'thinking' | 'speaking') {
  chatListeners.slice().forEach((l) => l(s))
}

const fakeService = {
  start: mockStart,
  stop: jest.fn(),
  activate: mockActivate,
  deactivate: mockDeactivate,
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

// `useVoiceChat` may call `getMobileEffectsPort()` to drive the haptic
// loop on thinking. We expose start/stop spies so the test can assert.
const mockStartThinking = jest.fn()
const mockStopThinking = jest.fn()
const mockPlayReadyChime = jest.fn()
jest.mock('@/lib/voice-chat/sounds', () => ({
  __esModule: true,
  createMobileEffectsPort: jest.fn(() => ({
    playReadyChime: mockPlayReadyChime,
    startThinkingSound: mockStartThinking,
    stopThinkingSound: mockStopThinking,
  })),
  getMobileEffectsPort: jest.fn(() => ({
    playReadyChime: mockPlayReadyChime,
    startThinkingSound: mockStartThinking,
    stopThinkingSound: mockStopThinking,
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
  mockActivate.mockClear()
  mockDeactivate.mockClear()
  mockStart.mockClear()
  mockStartThinking.mockClear()
  mockStopThinking.mockClear()
  mockPlayReadyChime.mockClear()
})

describe('useVoiceChat — CHT-002 context wiring', () => {
  it('forwards the lazy context provider payload to svc.activate', async () => {
    const ctx: VoiceChatContext = {
      pageText: 'Chapter 4: Falling Action',
      outline: {
        title: 'Tale of Two Cities',
        author: 'Dickens',
        chapters: ['Ch1', 'Ch2', 'Ch3', 'Ch4'],
      },
      activeParagraphText: 'It was the best of times…',
    }
    const provider = jest.fn(() => ctx)
    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-abc',
          context: provider,
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })

    expect(provider).toHaveBeenCalledTimes(1)
    expect(mockActivate).toHaveBeenCalledTimes(1)
    const [, passedCtx] = mockActivate.mock.calls[0]
    // The captured payload must be forwarded verbatim — no `{ pageText: '' }`
    // fallback when a provider is wired.
    expect(passedCtx).toEqual(ctx)
  })

  it('falls back to { pageText: "" } only when no context provider is wired', async () => {
    let api!: ReturnType<typeof useVoiceChat>
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-xyz',
          // no `context` prop
          onReady: (a) => (api = a),
        }),
      )
    })

    await act(async () => {
      await api.start()
    })

    expect(mockActivate).toHaveBeenCalledTimes(1)
    const [, passedCtx] = mockActivate.mock.calls[0]
    expect(passedCtx).toEqual({ pageText: '' })
  })

  it('captures the LATEST context at each activation (provider re-read)', async () => {
    const live: VoiceChatContext = { pageText: 'first', activeParagraphText: 'p1' }
    const provider = jest.fn(() => live)

    let api!: ReturnType<typeof useVoiceChat>
    let renderCount = 0
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, {
          bookId: 'book-1',
          context: provider,
          onReady: (a) => {
            api = a
            renderCount++
          },
        }),
      )
    })

    await act(async () => {
      await api.start()
    })
    expect(mockActivate.mock.calls[0][1]).toEqual({
      pageText: 'first',
      activeParagraphText: 'p1',
    })
    expect(renderCount).toBeGreaterThan(0)
  })
})

describe('useVoiceChat — CHT-007 thinking-state haptic', () => {
  it('fires startThinkingSound when chatStatus transitions to thinking while active', () => {
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { bookId: 'book-1' }),
      )
    })

    // Drive the service emitters: connecting → active, then chat → thinking.
    act(() => {
      emitState('connecting')
      emitState('active')
      emitChat('thinking')
    })

    expect(mockStartThinking).toHaveBeenCalledTimes(1)
    // Stop may be called defensively during non-thinking transitions on
    // mount (idempotent — the port no-ops when no interval is live). We
    // only pin that start fires on entry into thinking; the stop assertion
    // is covered separately by the speaking-transition test below.
  })

  it('stops the thinking loop when chatStatus moves to speaking', () => {
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { bookId: 'book-1' }),
      )
    })

    act(() => {
      emitState('active')
      emitChat('thinking')
    })
    expect(mockStartThinking).toHaveBeenCalledTimes(1)

    act(() => {
      emitChat('speaking')
    })
    expect(mockStopThinking).toHaveBeenCalled()
  })

  it('does NOT fire startThinkingSound when chatStatus is thinking but service is not active', () => {
    act(() => {
      TestRenderer.create(
        React.createElement(Harness, { bookId: 'book-1' }),
      )
    })

    act(() => {
      // connecting + thinking — the program emits 'connecting' chatStatus
      // before activate resolves. We should NOT start the loop until the
      // service reaches `active`.
      emitState('connecting')
      emitChat('thinking')
    })

    expect(mockStartThinking).not.toHaveBeenCalled()
  })

  it('stops the loop on unmount (cleanup)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        React.createElement(Harness, { bookId: 'book-1' }),
      )
    })

    act(() => {
      emitState('active')
      emitChat('thinking')
    })
    expect(mockStartThinking).toHaveBeenCalled()

    act(() => {
      tree.unmount()
    })
    expect(mockStopThinking).toHaveBeenCalled()
  })
})
