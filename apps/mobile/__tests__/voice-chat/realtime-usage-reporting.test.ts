/**
 * Usage-reporting wiring for the mobile realtime session.
 *
 * Verifies that:
 *   - Each `response.done` data-channel event accumulates its `usage`
 *     into a per-session accumulator (split across audio/text input/output).
 *   - On session close, the accumulated total is reported once via
 *     `apiClient('/api/billing/realtime-usage', POST, body)`.
 *   - Sessions that never received a `response.done` (zero usage) do not
 *     POST.
 *   - A reporter failure (apiClient throws OR returns a non-2xx Response)
 *     does NOT throw out of `session.close()` — voice chat must not break
 *     because billing reporting failed.
 *   - Per-session isolation: a second session, started after the first
 *     closes, starts at zero usage (no leaks across sessions).
 */

// ── react-native-webrtc minimal mock ───────────────────────────────────────
const mockAddTrack = jest.fn()
const mockCreateOffer = jest.fn().mockResolvedValue({ type: 'offer', sdp: 'v=0 offer' })
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

const mockTrack = { stop: jest.fn(), kind: 'audio', enabled: true }

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
  mediaDevices: { getUserMedia: jest.fn() },
  MediaStream: jest.fn(),
}), { virtual: true })

jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  PermissionsAndroid: {
    request: jest.fn(),
    PERMISSIONS: { RECORD_AUDIO: 'x' },
    RESULTS: { GRANTED: 'granted' },
  },
  Alert: { alert: jest.fn() },
}), { virtual: true })

jest.mock('react-native-view-shot', () => ({
  captureRef: jest.fn(),
}), { virtual: true })

// apiClient — capture all calls so we can assert POST body / call count.
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

// ── module under test ─────────────────────────────────────────────────────
import {
  mobileWebrtcFactory,
  mobileAgentFactory,
  mobileSessionFactory,
} from '@/lib/voice-chat/realtime-session'
import type { VoiceChatRagPort } from '@rishi/shared/voice-chat'

// ── helpers ────────────────────────────────────────────────────────────────
function buildSession() {
  const rag: VoiceChatRagPort = {
    searchSemantic: jest.fn().mockResolvedValue([]),
  }
  const transport = mobileWebrtcFactory({
    mediaStream: { getTracks: () => [mockTrack] } as never,
    audioElement: { muted: true, srcObject: null, autoplay: true, pause: () => undefined },
  })
  const agent = mobileAgentFactory({
    bookId: 1,
    pageText: 'p',
    language: 'en',
    onEndConversation: jest.fn(),
    rag,
  })
  const session = mobileSessionFactory(agent, {
    transport,
    apiKey: 'k',
    serverVad: { threshold: 0.7, silenceDurationMs: 700, prefixPaddingMs: 300 },
  })
  return session
}

function makeResponseDone(usage: {
  input_audio?: number
  input_text?: number
  output_audio?: number
  output_text?: number
}): string {
  return JSON.stringify({
    type: 'response.done',
    response: {
      usage: {
        input_token_details: {
          audio_tokens: usage.input_audio ?? 0,
          text_tokens: usage.input_text ?? 0,
        },
        output_token_details: {
          audio_tokens: usage.output_audio ?? 0,
          text_tokens: usage.output_text ?? 0,
        },
      },
    },
  })
}

function getRealtimeUsagePost():
  | { path: string; init: { method?: string; body?: string; headers?: Record<string, string> } }
  | undefined {
  const call = mockApiClient.mock.calls.find(
    (c: unknown[]) => c[0] === '/api/billing/realtime-usage',
  )
  if (!call) return undefined
  return { path: call[0] as string, init: (call[1] ?? {}) as { method?: string; body?: string } }
}

async function flushMicrotasks(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

// ── tests ──────────────────────────────────────────────────────────────────
describe('mobile realtime-session — usage reporting wiring', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    mockDataChannel.onopen = null
    mockDataChannel.onmessage = null
    mockApiClient.mockResolvedValue({ ok: true, status: 200, json: async () => ({}), text: async () => '' })
  })

  it('accumulates usage across multiple response.done events and reports the total on close', async () => {
    const session = buildSession()
    mockDataChannel.onopen!()

    mockDataChannel.onmessage!({
      data: makeResponseDone({ input_audio: 100, input_text: 5, output_audio: 50, output_text: 2 }),
    })
    mockDataChannel.onmessage!({
      data: makeResponseDone({ input_audio: 30, input_text: 1, output_audio: 20, output_text: 4 }),
    })

    session.close()
    await flushMicrotasks()

    const post = getRealtimeUsagePost()
    expect(post).toBeDefined()
    expect(post!.init.method).toBe('POST')

    const body = JSON.parse(post!.init.body as string)
    expect(body).toEqual({
      audioInputTokens: 130,
      audioOutputTokens: 70,
      textInputTokens: 6,
      textOutputTokens: 6,
    })
  })

  it('does not POST to /api/billing/realtime-usage when no response.done fired (zero usage)', async () => {
    const session = buildSession()
    mockDataChannel.onopen!()

    session.close()
    await flushMicrotasks()

    expect(getRealtimeUsagePost()).toBeUndefined()
  })

  it('does not throw out of close() when apiClient rejects', async () => {
    mockApiClient.mockRejectedValue(new Error('network down'))

    const session = buildSession()
    mockDataChannel.onopen!()
    mockDataChannel.onmessage!({
      data: makeResponseDone({ input_audio: 10, output_audio: 5 }),
    })

    expect(() => session.close()).not.toThrow()
    await flushMicrotasks()
  })

  it('does not throw out of close() when apiClient returns non-2xx', async () => {
    mockApiClient.mockResolvedValue({ ok: false, status: 500, text: async () => 'oops' })

    const session = buildSession()
    mockDataChannel.onopen!()
    mockDataChannel.onmessage!({
      data: makeResponseDone({ input_audio: 10, output_audio: 5 }),
    })

    expect(() => session.close()).not.toThrow()
    await flushMicrotasks()
  })

  it('per-session isolation — a new session starts with zero usage (no leak from the previous one)', async () => {
    // Session 1: accumulate then close.
    const s1 = buildSession()
    mockDataChannel.onopen!()
    mockDataChannel.onmessage!({
      data: makeResponseDone({ input_audio: 999, output_audio: 999 }),
    })
    s1.close()
    await flushMicrotasks()

    mockApiClient.mockClear()

    // Session 2: NO response.done — must NOT POST anything.
    const s2 = buildSession()
    mockDataChannel.onopen!()
    s2.close()
    await flushMicrotasks()

    const post = getRealtimeUsagePost()
    expect(post).toBeUndefined()
  })
})
