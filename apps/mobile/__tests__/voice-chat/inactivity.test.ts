/**
 * CG40 — voice-chat inactivity timeout.
 *
 * The shared service schedules an inactivity timer the moment a chat-status
 * event fires while a session is alive. If no further activity arrives
 * within `config.inactivityTimeoutMs`, the service:
 *
 *   1. emits `endedByAgent('inactivity_timeout')`,
 *   2. disposes the session (PC + DC closed, mic released),
 *   3. transitions the public state back to `'idle'`.
 *
 * Today the only test of the timer path covers the connect timeout. This
 * file covers the inactivity-timer-fired-mid-session case using jest fake
 * timers so the 3-min wall-clock isn't real.
 *
 * Lives in its own file (NOT extending `service.test.ts`) to keep the
 * fake-timer scope tight — the broader service tests rely on real
 * promise scheduling and switching to fake timers can flake them.
 */

const mockAddTrack = jest.fn()
const mockCreateOffer = jest.fn().mockResolvedValue({ type: 'offer', sdp: 'v=0' })
const mockSetLocalDescription = jest.fn().mockResolvedValue(undefined)
const mockSetRemoteDescription = jest.fn().mockResolvedValue(undefined)
const mockClosePC = jest.fn()
const mockGetSenders = jest.fn().mockReturnValue([])

const mockDcSend = jest.fn()
const mockDcClose = jest.fn()
const mockDataChannel = {
  send: mockDcSend,
  close: mockDcClose,
  onopen: null as (() => void) | null,
  onmessage: null as ((event: { data: string }) => void) | null,
}
const mockCreateDataChannel = jest.fn().mockReturnValue(mockDataChannel)

const mockTrack = { stop: jest.fn(), kind: 'audio', enabled: true, clone: jest.fn() }
mockTrack.clone.mockReturnValue({ ...mockTrack, enabled: false })
const mockGetUserMedia = jest.fn().mockResolvedValue({
  getTracks: () => [mockTrack],
})

jest.mock('react-native-webrtc', () => ({
  RTCPeerConnection: jest.fn().mockImplementation(() => ({
    createDataChannel: mockCreateDataChannel,
    addTrack: mockAddTrack,
    createOffer: mockCreateOffer,
    setLocalDescription: mockSetLocalDescription,
    setRemoteDescription: mockSetRemoteDescription,
    getSenders: mockGetSenders,
    close: mockClosePC,
  })),
  mediaDevices: { getUserMedia: mockGetUserMedia },
  MediaStream: jest.fn().mockImplementation(() => ({ getTracks: () => [mockTrack] })),
}), { virtual: true })

jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  PermissionsAndroid: {
    request: jest.fn().mockResolvedValue('granted'),
    PERMISSIONS: { RECORD_AUDIO: 'android.permission.RECORD_AUDIO' },
    RESULTS: { GRANTED: 'granted' },
  },
  Alert: { alert: jest.fn() },
}), { virtual: true })

jest.mock('expo-audio', () => ({
  createAudioPlayer: jest.fn().mockReturnValue({ play: jest.fn(), remove: jest.fn(), volume: 1 }),
}), { virtual: true })

jest.mock('expo-file-system', () => ({
  File: jest.fn().mockImplementation(() => ({ exists: true, uri: 'file:///chime.wav', write: jest.fn() })),
  Paths: { cache: 'file:///cache/' },
}), { virtual: true })

jest.mock('react-native-view-shot', () => ({
  captureRef: jest.fn().mockResolvedValue('data:image/jpeg;base64,XXX'),
}), { virtual: true })

jest.mock('@/lib/rag/vector-store', () => ({
  searchSimilarChunks: jest.fn().mockReturnValue([]),
}))
jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(),
  isEmbeddingReady: jest.fn().mockReturnValue(false),
}))
jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: jest.fn().mockResolvedValue([[0.1, 0.2]]),
}))

const mockApiClient = jest.fn().mockResolvedValue({
  ok: true,
  json: async () => ({ client_secret: { value: 'TEST-KEY' } }),
  text: async () => '',
})
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

jest.mock('@/lib/connectivity/MobileConnectivityPort', () => ({
  createMobileConnectivityPort: () => ({
    isOnline: () => true,
    subscribe: () => () => undefined,
  }),
}))

const origFetch = global.fetch
beforeAll(() => {
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    text: async () => 'v=0 answer',
  }) as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = origFetch
})

import {
  getVoiceChatService,
  _resetVoiceChatServiceForTests,
} from '@/lib/voice-chat/service'

describe('voice-chat inactivity timer (CG40)', () => {
  beforeEach(() => {
    _resetVoiceChatServiceForTests()
    jest.clearAllMocks()
    mockApiClient.mockResolvedValue({
      ok: true,
      json: async () => ({ client_secret: { value: 'TEST-KEY' } }),
      text: async () => '',
    })
    mockTrack.clone.mockReturnValue({ ...mockTrack, enabled: false })
  })

  it('fires endedByAgent("inactivity_timeout") after config.inactivityTimeoutMs of silence', async () => {
    // Override the default 3-min timeout to 1 second so the test runs
    // synchronously against jest fake-timers without sitting on real
    // wall-clock for minutes.
    jest.useFakeTimers()
    try {
      // Initialize the service with a custom config BEFORE the
      // singleton is built (the cache reset above ensures the new opts
      // win).
      const svc = getVoiceChatService({
        config: { inactivityTimeoutMs: 1000 },
      })

      const reasons: string[] = []
      svc.onEndedByAgent((r) => reasons.push(r))

      await svc.activate(1, { pageText: 'p' })
      expect(svc.getState()).toBe('active')

      // The inactivity timer is started/restarted on each chat-status
      // emission. The activation pipeline emits 'idle' on success.
      // Advance jest's clock past the inactivity threshold.
      jest.advanceTimersByTime(1500)

      // Drain microtasks queued by the timer's callback.
      await Promise.resolve()
      await Promise.resolve()

      // The agent-end reason should be the special 'inactivity_timeout'
      // sentinel the shared service emits.
      expect(reasons).toContain('inactivity_timeout')
      // And the service has been disposed — public state is back to idle.
      expect(svc.getState()).toBe('idle')
      // The peer connection was closed.
      expect(mockClosePC).toHaveBeenCalled()
    } finally {
      jest.useRealTimers()
    }
  })

  it('does NOT fire when activity (chat-status events) keeps coming in', async () => {
    jest.useFakeTimers()
    try {
      const svc = getVoiceChatService({
        config: { inactivityTimeoutMs: 1000 },
      })

      const reasons: string[] = []
      svc.onEndedByAgent((r) => reasons.push(r))

      await svc.activate(1, { pageText: 'p' })

      // Halfway through the timeout, drive an activity event to RESET
      // the timer (the activation pipeline subscribes to data-channel
      // messages and forwards them as chat-status — we simulate the
      // raw 'response.created' to trigger 'agent_start' → chat-status
      // emission).
      jest.advanceTimersByTime(500)
      mockDataChannel.onmessage!({
        data: JSON.stringify({ type: 'response.created' }),
      })
      // After this the timer should be RESCHEDULED for a fresh 1000ms.

      // Advance by 800ms — total elapsed since the LAST reset is 800ms
      // which is under the threshold.
      jest.advanceTimersByTime(800)
      await Promise.resolve()

      // No timeout reason fired yet.
      expect(reasons).not.toContain('inactivity_timeout')
      // Still active.
      expect(svc.getState()).toBe('active')
    } finally {
      jest.useRealTimers()
    }
  })
})
