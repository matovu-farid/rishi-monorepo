/**
 * T-P2.2 — BILLING-AUDIT-001 mobile realtime-usage integration test.
 *
 * Asserts that the mobile realtime-session lifecycle:
 *   - Accumulates `response.done` event usage into a per-session total
 *     (audio + text in/out tokens).
 *   - On `session.close()`, flushes that total and POSTs once to
 *     `/api/billing/realtime-usage`.
 *   - When no `response.done` arrives during the session, NO POST is made.
 *   - Multiple `response.done` events sum into a single POST on close.
 *   - apiClient failures during the POST do NOT propagate out of `close()`.
 *
 * RED until `apps/mobile/lib/voice-chat/realtime-session.ts` is wired
 * to the shared `RealtimeUsageAccumulator` + `reportRealtimeUsage` client
 * (see SPEC §3.1 / §4.0a, PLAN T-P2.2).
 */

// ── react-native-webrtc minimal mock ───────────────────────────────────────
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

// Capture all apiClient calls so the test can assert on the realtime-usage POST.
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

// ── Module under test ─────────────────────────────────────────────────────
import {
  mobileWebrtcFactory,
  mobileAgentFactory,
  mobileSessionFactory,
} from '@/lib/voice-chat/realtime-session'
import type { VoiceChatRagPort } from '@rishi/shared/voice-chat'

const REALTIME_USAGE_PATH = '/api/billing/realtime-usage'

function buildSession() {
  const rag: VoiceChatRagPort = {
    searchSemantic: jest.fn().mockResolvedValue([]),
  }
  const transport = mobileWebrtcFactory({
    mediaStream: { getTracks: () => [mockTrack] } as never,
    audioElement: {
      muted: true,
      srcObject: null,
      autoplay: true,
      pause: () => undefined,
    },
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

/** Drive a `response.done` event through the captured data-channel handler. */
function pushResponseDone(usage: Record<string, unknown> | undefined): void {
  const onmessage = mockDataChannel.onmessage
  if (!onmessage) throw new Error('data-channel onmessage not registered')
  onmessage({
    data: JSON.stringify({
      type: 'response.done',
      response: usage ? { usage } : undefined,
    }),
  })
}

beforeEach(() => {
  jest.clearAllMocks()
  mockApiClient.mockReset()
  mockApiClient.mockResolvedValue(
    new Response(JSON.stringify({ ok: true }), { status: 200 }),
  )
})

describe('BILLING-AUDIT-001 — mobile realtime-usage reporting (integration)', () => {
  it('POSTs the summed usage exactly once on session.close()', async () => {
    const session = buildSession()
    // simulate data-channel open so subsequent sends are accepted (not needed
    // for the inbound usage path, but mirrors a real session lifecycle).
    mockDataChannel.onopen?.()

    pushResponseDone({
      input_token_details: { audio_tokens: 100, text_tokens: 50 },
      output_token_details: { audio_tokens: 200, text_tokens: 75 },
    })

    session.close()
    await Promise.resolve()
    await Promise.resolve()

    const usageCalls = mockApiClient.mock.calls.filter(
      ([path]) => path === REALTIME_USAGE_PATH,
    )
    expect(usageCalls).toHaveLength(1)

    const [, init] = usageCalls[0]!
    expect(init?.method).toBe('POST')
    const body = JSON.parse(String(init?.body)) as Record<string, number>
    expect(body).toEqual({
      audioInputTokens: 100,
      audioOutputTokens: 200,
      textInputTokens: 50,
      textOutputTokens: 75,
    })
  })

  it('does NOT POST when the session closes without any response.done usage', async () => {
    const session = buildSession()
    mockDataChannel.onopen?.()

    // No response.done emitted.
    session.close()
    await Promise.resolve()
    await Promise.resolve()

    const usageCalls = mockApiClient.mock.calls.filter(
      ([path]) => path === REALTIME_USAGE_PATH,
    )
    expect(usageCalls).toHaveLength(0)
  })

  it('does NOT POST when response.done arrives without a usage payload', async () => {
    const session = buildSession()
    mockDataChannel.onopen?.()

    // response.done with no `response.usage` — must not contribute counters.
    pushResponseDone(undefined)
    session.close()
    await Promise.resolve()
    await Promise.resolve()

    const usageCalls = mockApiClient.mock.calls.filter(
      ([path]) => path === REALTIME_USAGE_PATH,
    )
    expect(usageCalls).toHaveLength(0)
  })

  it('sums multiple response.done events into a single POST on close', async () => {
    const session = buildSession()
    mockDataChannel.onopen?.()

    pushResponseDone({
      input_token_details: { audio_tokens: 10, text_tokens: 5 },
      output_token_details: { audio_tokens: 20, text_tokens: 7 },
    })
    pushResponseDone({
      input_token_details: { audio_tokens: 1, text_tokens: 2 },
      output_token_details: { audio_tokens: 3, text_tokens: 4 },
    })

    session.close()
    await Promise.resolve()
    await Promise.resolve()

    const usageCalls = mockApiClient.mock.calls.filter(
      ([path]) => path === REALTIME_USAGE_PATH,
    )
    expect(usageCalls).toHaveLength(1)
    const body = JSON.parse(String(usageCalls[0]?.[1]?.body)) as Record<string, number>
    expect(body).toEqual({
      audioInputTokens: 11,
      audioOutputTokens: 23,
      textInputTokens: 7,
      textOutputTokens: 11,
    })
  })

  it('does NOT throw out of close() when the apiClient POST rejects', async () => {
    mockApiClient.mockReset()
    // First call (or all calls) reject.
    mockApiClient.mockRejectedValue(new Error('network down'))

    const session = buildSession()
    mockDataChannel.onopen?.()

    pushResponseDone({
      input_token_details: { audio_tokens: 1, text_tokens: 1 },
      output_token_details: { audio_tokens: 1, text_tokens: 1 },
    })

    expect(() => session.close()).not.toThrow()
    // Flush the rejected promise so jest doesn't print an unhandled
    // rejection warning AFTER the test has resolved.
    await Promise.resolve()
    await Promise.resolve()
  })

  it('does NOT throw out of close() when the apiClient POST returns non-2xx', async () => {
    mockApiClient.mockReset()
    mockApiClient.mockResolvedValue(
      new Response('forbidden', { status: 402 }),
    )

    const session = buildSession()
    mockDataChannel.onopen?.()

    pushResponseDone({
      input_token_details: { audio_tokens: 1, text_tokens: 1 },
      output_token_details: { audio_tokens: 1, text_tokens: 1 },
    })

    expect(() => session.close()).not.toThrow()
    await Promise.resolve()
    await Promise.resolve()
  })
})
