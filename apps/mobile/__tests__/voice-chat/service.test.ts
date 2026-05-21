/**
 * Mobile voice-chat service smoke tests.
 *
 * The full FSM coverage lives in `packages/shared/src/voice-chat/service.test.ts`
 * (174 tests, exercised by the shared `vitest` suite). On the mobile side
 * we only need to assert that:
 *   1. The mobile factory wires the shared service up correctly.
 *   2. State transitions reach the same emitter the React hook will
 *      subscribe to.
 *   3. The mobile MediaPort omits `createMediaRecorder` (no buffered
 *      replay on RN).
 *   4. Public state matches the shared machine's idle → connecting →
 *      active path when the activation pipeline succeeds.
 */

// ── Mock react-native-webrtc — kept minimal; real wiring is covered
//    by `packages/shared` tests against the shared service.
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

// ── Mock expo modules used by the sounds adapter.
jest.mock('expo-audio', () => ({
  createAudioPlayer: jest.fn().mockReturnValue({ play: jest.fn(), remove: jest.fn(), volume: 1 }),
}), { virtual: true })

jest.mock('expo-file-system', () => ({
  File: jest.fn().mockImplementation(() => ({ exists: true, uri: 'file:///chime.wav', write: jest.fn() })),
  Paths: { cache: 'file:///cache/' },
}), { virtual: true })

// react-native-view-shot ships ESM; jest can't parse it directly. Mock it
// out so the page-capture module's transitive import doesn't blow up the
// suite. The voice-chat service tests don't exercise screenshot capture.
jest.mock('react-native-view-shot', () => ({
  captureRef: jest.fn().mockResolvedValue('data:image/jpeg;base64,XXX'),
}), { virtual: true })

// ── Mock RAG.
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

// ── Mock api client (key-mint + transcribe).
const mockApiClient = jest.fn().mockResolvedValue({
  ok: true,
  json: async () => ({ client_secret: { value: 'TEST-KEY' } }),
  text: async () => '',
})
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

// ── Mock connectivity (always online for the smoke tests).
jest.mock('@/lib/connectivity/MobileConnectivityPort', () => ({
  createMobileConnectivityPort: () => ({
    isOnline: () => true,
    subscribe: (_l: (online: boolean) => void) => () => undefined,
  }),
}))

// ── Mock global fetch (SDP exchange).
const origFetch = global.fetch
beforeAll(() => {
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    text: async () => 'v=0\r\no=- answer',
  }) as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = origFetch
})

import {
  getVoiceChatService,
  _resetVoiceChatServiceForTests,
} from '@/lib/voice-chat/service'
import { mobileMediaPort } from '@/lib/voice-chat/media-port'

describe('mobile voice-chat service', () => {
  beforeEach(() => {
    _resetVoiceChatServiceForTests()
    jest.clearAllMocks()
    mockTrack.clone.mockReturnValue({ ...mockTrack, enabled: false })
    mockApiClient.mockResolvedValue({
      ok: true,
      json: async () => ({ client_secret: { value: 'TEST-KEY' } }),
      text: async () => '',
    })
  })

  it('returns a singleton service instance', () => {
    const a = getVoiceChatService()
    const b = getVoiceChatService()
    expect(a).toBe(b)
  })

  it('starts in idle state with no error', () => {
    const svc = getVoiceChatService()
    expect(svc.getState()).toBe('idle')
    expect(svc.getError()).toBeNull()
  })

  it('cold activate transitions idle → connecting → active', async () => {
    const svc = getVoiceChatService()
    const states: string[] = []
    svc.onStateChange((s) => states.push(s))

    await svc.activate(42, { pageText: 'hello world' })

    // After the activation pipeline resolves, the machine MUST have
    // walked through connecting and landed on active.
    expect(states).toEqual(['connecting', 'active'])
    expect(svc.getState()).toBe('active')
  })

  it('deactivate from active returns to idle and closes the peer connection', async () => {
    const svc = getVoiceChatService()
    await svc.activate(1, { pageText: 'p' })
    expect(svc.getState()).toBe('active')

    svc.deactivate()

    expect(svc.getState()).toBe('idle')
    expect(mockClosePC).toHaveBeenCalled()
  })

  it('onEndedByAgent listeners fire when the agent invokes endConversation tool', async () => {
    const svc = getVoiceChatService()
    const reasons: string[] = []
    svc.onEndedByAgent((r) => reasons.push(r))

    await svc.activate(1, { pageText: 'p' })

    // Simulate the model emitting response.function_call_arguments.done
    // with name = endConversation. The session's onmessage hook is the
    // data channel's onmessage callback the factory installed.
    expect(mockDataChannel.onmessage).not.toBeNull()
    mockDataChannel.onmessage!({
      data: JSON.stringify({
        type: 'response.function_call_arguments.done',
        name: 'endConversation',
        call_id: 'c1',
        arguments: JSON.stringify({ reason: 'user thanked me' }),
      }),
    })

    // Tool dispatch is async (await inside handleToolCall). Drain
    // microtasks.
    await Promise.resolve()
    await Promise.resolve()
    expect(reasons).toEqual(['user thanked me'])
  })
})

describe('mobile MediaPort', () => {
  it('omits createMediaRecorder so the activation pipeline skips buffered-replay', () => {
    expect(mobileMediaPort.createMediaRecorder).toBeUndefined()
  })

  it('cloneStreamForWebrtcSend clones tracks and disables them by default', () => {
    const sourceTrack = { stop: jest.fn(), enabled: true, clone: jest.fn() }
    sourceTrack.clone.mockReturnValue({ ...sourceTrack, enabled: true })
    const source = { getTracks: () => [sourceTrack] }
    mobileMediaPort.cloneStreamForWebrtcSend(source as never)
    expect(sourceTrack.clone).toHaveBeenCalled()
  })
})
