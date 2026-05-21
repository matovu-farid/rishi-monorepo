/**
 * Realtime-session direct unit tests (Phase C: CG06, CG07, CG28, CG29).
 *
 * `apps/mobile/lib/voice-chat/realtime-session.ts` is ~399 LOC and was
 * previously covered only indirectly via `service.test.ts`. The direct
 * tests below exercise:
 *
 *   - CG06: tool-dispatch error path — when the bookContext tool throws
 *     inside `handleToolCall`, the session MUST emit `'error'` AND still
 *     respond with `function_call_output` carrying the error message
 *     (so the model isn't left waiting for a tool reply).
 *   - CG07: SDP-exchange non-200 — `session.connect()` MUST throw and
 *     MUST NOT call `pc.setRemoteDescription`.
 *   - CG28: mic permission denied — when `mediaDevices.getUserMedia`
 *     rejects with NotAllowedError, the activation flow via
 *     `mobileWebrtcFactory`/service surfaces a `mic_denied`-reason
 *     VoiceError on the public service emitter.
 *   - CG29: ephemeral key 401 — when the worker's
 *     `/api/realtime/client_secrets` returns 401, the service MUST NOT
 *     trigger `signOut()` (this is a session-scoped failure, not an
 *     auth-scoped one), and the activation MUST surface an
 *     `auth_failed` voice-error via the public error emitter.
 *
 *   - Plus the two P2 items the same audit row lists:
 *     - CG28-bonus: `interrupt()` sends `response.cancel` exactly once.
 *     - CG29-bonus: `updateAgent` re-emits a `session.update` with the
 *       new instructions text.
 *
 * The realtime-session module is exercised directly using the public
 * `mobileWebrtcFactory` + `mobileAgentFactory` + `mobileSessionFactory`
 * exports (the same wiring the production service uses). We mock
 * `react-native-webrtc`, `react-native-view-shot`, and `fetch`.
 */

// ── react-native-webrtc — minimal mock keeping per-test control ─────────────
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

// react-native-view-shot is ESM; jest can't parse it. Stub captureRef so
// the page-capture module loads (it's transitively imported via
// realtime-session.ts for the inspectCurrentPage tool path).
jest.mock('react-native-view-shot', () => ({
  captureRef: jest.fn().mockResolvedValue('data:image/jpeg;base64,XYZ'),
}), { virtual: true })

// expo modules used downstream by the voice-chat service (but harmless
// here — keep them so the broader voice-chat service tests still pass
// if this file is added to the same suite).
jest.mock('expo-audio', () => ({
  createAudioPlayer: jest.fn().mockReturnValue({ play: jest.fn(), remove: jest.fn(), volume: 1 }),
}), { virtual: true })

jest.mock('expo-file-system', () => ({
  File: jest.fn().mockImplementation(() => ({ exists: true, uri: 'file:///chime.wav', write: jest.fn() })),
  Paths: { cache: 'file:///cache/' },
}), { virtual: true })

// RAG ports — the session's bookContext tool calls these via the agent.
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

// Connectivity port — always online for these tests.
jest.mock('@/lib/connectivity/MobileConnectivityPort', () => ({
  createMobileConnectivityPort: () => ({
    isOnline: () => true,
    subscribe: (_l: (online: boolean) => void) => () => undefined,
  }),
}))

// apiClient mock — controlled per test. Used both by the IPC port (key
// mint) and (indirectly) by any feature that wants `signOut` to NOT
// fire on a session-scoped 401. We capture every call so we can assert
// "signOut() was never called for a 401 from /client_secrets".
const mockApiClient = jest.fn()
jest.mock('@/lib/api', () => ({ apiClient: mockApiClient }))

const mockSignOut = jest.fn()
jest.mock('@/lib/auth', () => ({
  signOut: mockSignOut,
  getSessionToken: jest.fn().mockResolvedValue('mock-token'),
  WORKER_API_URL: 'https://api.example.com',
}))

// ── module-under-test ──────────────────────────────────────────────────────
import {
  mobileWebrtcFactory,
  mobileAgentFactory,
  mobileSessionFactory,
} from '@/lib/voice-chat/realtime-session'
import type { VoiceChatRagPort } from '@rishi/shared/voice-chat'
import {
  getVoiceChatService,
  _resetVoiceChatServiceForTests,
} from '@/lib/voice-chat/service'

// ── fetch mock — controlled per test ───────────────────────────────────────
const origFetch = global.fetch
let mockFetch: jest.Mock

beforeEach(() => {
  jest.clearAllMocks()
  mockDataChannel.onopen = null
  mockDataChannel.onmessage = null
  mockFetch = jest.fn().mockResolvedValue({
    ok: true,
    status: 200,
    text: async () => 'v=0 answer',
  })
  global.fetch = mockFetch as unknown as typeof fetch
})

afterEach(() => {
  global.fetch = origFetch
})

// ── helpers ────────────────────────────────────────────────────────────────
function buildSession(opts: {
  rag?: VoiceChatRagPort
  bookId?: number
  visualSummary?: { equations: number; figures: number; images: number }
}) {
  const rag = opts.rag ?? {
    searchSemantic: jest.fn().mockResolvedValue([]),
  }
  const transport = mobileWebrtcFactory({
    mediaStream: { getTracks: () => [mockTrack] } as never,
    audioElement: { muted: true, srcObject: null, autoplay: true, pause: () => undefined },
  })
  const agent = mobileAgentFactory({
    bookId: opts.bookId ?? 7,
    pageText: 'hello world',
    language: 'en',
    onEndConversation: jest.fn(),
    rag,
    visualSummary: opts.visualSummary,
  })
  const session = mobileSessionFactory(agent, {
    transport,
    apiKey: 'test-key',
    serverVad: { threshold: 0.7, silenceDurationMs: 700, prefixPaddingMs: 300 },
  })
  return { session, rag }
}

// ── tests ──────────────────────────────────────────────────────────────────

describe('realtime-session (mobile)', () => {
  describe('CG06: tool-dispatch error path', () => {
    it('emits an "error" event when the bookContext tool throws AND still replies with function_call_output carrying the error message', async () => {
      const ragError = new Error('RAG embedding failed: worker 500')
      const rag: VoiceChatRagPort = {
        searchSemantic: jest.fn().mockRejectedValue(ragError),
      }

      const { session } = buildSession({ rag })

      const errors: unknown[] = []
      session.on('error', (e) => errors.push(e))

      // Simulate the channel opening (so isConnected = true) — required
      // for the send() guard inside handleToolCall to actually fire the
      // function_call_output.
      mockDataChannel.onopen!()

      // Drive a function-call message into the data channel.
      mockDataChannel.onmessage!({
        data: JSON.stringify({
          type: 'response.function_call_arguments.done',
          name: 'bookContext',
          call_id: 'call-1',
          arguments: JSON.stringify({ queryText: 'what is dharma?' }),
        }),
      })

      // Drain the awaited promise inside handleToolCall.
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()

      // The session emitted 'error' with the rejection — NOT swallowed.
      expect(errors).toHaveLength(1)
      expect(errors[0]).toBe(ragError)

      // The session still sent a function_call_output so the model can
      // recover instead of hanging.
      const outputMessages = mockDcSend.mock.calls
        .map((c) => JSON.parse(c[0] as string))
        .filter((m) => m.type === 'conversation.item.create' && m.item?.type === 'function_call_output')
      expect(outputMessages).toHaveLength(1)
      expect(outputMessages[0].item.call_id).toBe('call-1')
      expect(outputMessages[0].item.output).toContain('RAG embedding failed')
    })
  })

  describe('CG07: SDP exchange non-200', () => {
    it('connect() throws when /v1/realtime returns a non-2xx response AND never calls setRemoteDescription', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 500,
        text: async () => 'upstream broken',
      })

      const { session } = buildSession({})

      await expect(session.connect({ apiKey: 'KEY' })).rejects.toThrow(/SDP exchange failed.*500/)

      // We must have offered + set the local description but never set
      // the remote description (no answer arrived).
      expect(mockCreateOffer).toHaveBeenCalledTimes(1)
      expect(mockSetLocalDescription).toHaveBeenCalledTimes(1)
      expect(mockSetRemoteDescription).not.toHaveBeenCalled()
    })

    it('connect() succeeds on 200 and applies the answer SDP to the remote description', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        status: 200,
        text: async () => 'v=0 answer-sdp',
      })

      const { session } = buildSession({})

      await session.connect({ apiKey: 'KEY' })

      expect(mockSetRemoteDescription).toHaveBeenCalledTimes(1)
      const arg = mockSetRemoteDescription.mock.calls[0][0] as { type: string; sdp: string }
      expect(arg.type).toBe('answer')
      expect(arg.sdp).toBe('v=0 answer-sdp')
    })
  })

  describe('CG28: mic permission denied surfaces structured error via the service', () => {
    beforeEach(() => {
      _resetVoiceChatServiceForTests()
      // Default per test — getUserMedia rejects with NotAllowedError.
      const denied = Object.assign(new Error('Permission denied'), {
        name: 'NotAllowedError',
      })
      mockGetUserMedia.mockRejectedValueOnce(denied)
      // The key cache get also has to succeed-or-not — irrelevant for this
      // test because the pipeline fails on getUserMedia FIRST.
      mockApiClient.mockResolvedValue({
        ok: true,
        json: async () => ({ client_secret: { value: 'KEY' } }),
        text: async () => '',
      })
    })

    it('activate() rejects and the service exposes a VoiceError with reason="mic_denied"', async () => {
      const svc = getVoiceChatService()
      const errors: Array<{ reason: string; message?: string }> = []
      // The public surface exposes errors via getError() after the
      // machine transitions; subscribe to state for the transition.
      svc.onStateChange(() => {
        const e = svc.getError()
        if (e) errors.push(e)
      })

      await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow(/Permission denied/i)

      const final = svc.getError()
      expect(final).not.toBeNull()
      expect(final?.reason).toBe('mic_denied')
    })
  })

  describe('CG29: ephemeral key 401 — does NOT trigger signOut + surfaces auth-error', () => {
    beforeEach(() => {
      _resetVoiceChatServiceForTests()
      // Reset mic to a working state.
      mockGetUserMedia.mockResolvedValue({ getTracks: () => [mockTrack] })
      // apiClient(/client_secrets) returns 401 — session-scoped failure.
      mockApiClient.mockResolvedValue({
        ok: false,
        status: 401,
        json: async () => ({ error: 'unauthorized' }),
        text: async () => 'unauthorized',
      })
    })

    it('a 401 from /api/realtime/client_secrets does NOT call signOut() (this is session-scoped, not auth-scoped)', async () => {
      const svc = getVoiceChatService()

      await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow()

      // CRITICAL: signOut must NOT have been triggered. A 401 from the
      // realtime key endpoint is a session-scoped error (e.g., feature
      // not enabled for this user) and must not destroy the user's
      // bearer token.
      expect(mockSignOut).not.toHaveBeenCalled()
    })

    it('the public error surface receives a VoiceError with reason="auth_failed" when the key mint returns 401', async () => {
      const svc = getVoiceChatService()
      await expect(svc.activate(1, { pageText: 'p' })).rejects.toThrow()
      const err = svc.getError()
      expect(err).not.toBeNull()
      expect(err?.reason).toBe('auth_failed')
      expect(err?.message ?? '').toMatch(/401|unauthor/i)
    })
  })

  // ── P2 follow-ups from the same audit row ──────────────────────────────
  describe('CG28-bonus: interrupt() sends response.cancel exactly once', () => {
    it('emits a single response.cancel data-channel message when connected', () => {
      const { session } = buildSession({})
      mockDataChannel.onopen!()
      session.interrupt()
      const cancels = mockDcSend.mock.calls
        .map((c) => JSON.parse(c[0] as string))
        .filter((m) => m.type === 'response.cancel')
      expect(cancels).toHaveLength(1)
    })

    it('does NOT send response.cancel when the data channel has never opened', () => {
      const { session } = buildSession({})
      session.interrupt()
      const cancels = mockDcSend.mock.calls
        .map((c) => JSON.parse(c[0] as string))
        .filter((m) => m.type === 'response.cancel')
      expect(cancels).toHaveLength(0)
    })
  })

  describe('CG29-bonus: updateAgent() re-emits session.update with the new instructions text', () => {
    it('the second session.update carries the new agent\'s instructions, not the original', async () => {
      const { session } = buildSession({})
      mockDataChannel.onopen!()

      // The initial session.update fires synchronously inside onopen.
      const initialUpdates = mockDcSend.mock.calls
        .map((c) => JSON.parse(c[0] as string))
        .filter((m) => m.type === 'session.update')
      expect(initialUpdates).toHaveLength(1)
      const initialInstructions = initialUpdates[0].session.instructions as string

      // Build a new agent with a different language so instructions change.
      const newAgent = mobileAgentFactory({
        bookId: 7,
        pageText: 'fresh page',
        language: 'es',
        onEndConversation: jest.fn(),
        rag: { searchSemantic: jest.fn().mockResolvedValue([]) },
      })

      await session.updateAgent(newAgent)

      const updates = mockDcSend.mock.calls
        .map((c) => JSON.parse(c[0] as string))
        .filter((m) => m.type === 'session.update')
      expect(updates.length).toBeGreaterThanOrEqual(2)
      const newInstructions = updates[updates.length - 1].session.instructions as string
      expect(newInstructions).not.toBe(initialInstructions)
      // The new instructions must mention the new language directive.
      expect(newInstructions).toMatch(/Spanish/)
    })
  })

  // ── Hunter-2 H2-01: cloned-track mic-release on close() ──────────────────
  //
  // Symptom: when the user ends a voice-chat session, the microphone LED
  // sometimes stays on. The shared service's disposeInternal() stops the
  // ORIGINAL mediaStream's tracks, but the CLONED tracks (the ones added
  // to the RTCPeerConnection by mobileWebrtcFactory) are independent
  // per WHATWG spec: `MediaStreamTrack.clone()` produces a separate track
  // that does NOT stop when the source is stopped.
  //
  // Fix: session.close() must stop the cloned tracks held by the transport
  // before closing the PC. Otherwise the cloned tracks keep the OS mic
  // resource alive until the GC frees the PC senders (or never).
  describe('H2-01: close() must release the cloned mic tracks', () => {
    it('stops every track on the transport sendStream when close() is called', () => {
      const clonedTrack = { stop: jest.fn(), kind: 'audio', enabled: true }
      const sendStream = {
        getTracks: jest.fn(() => [clonedTrack]),
      }
      const transport = mobileWebrtcFactory({
        mediaStream: sendStream as never,
        audioElement: { muted: true, srcObject: null, autoplay: true, pause: () => undefined },
      })
      const agent = mobileAgentFactory({
        bookId: 7,
        pageText: 'p',
        language: 'en',
        onEndConversation: jest.fn(),
        rag: { searchSemantic: jest.fn().mockResolvedValue([]) },
      })
      const session = mobileSessionFactory(agent, {
        transport,
        apiKey: 'test-key',
        serverVad: { threshold: 0.7, silenceDurationMs: 700, prefixPaddingMs: 300 },
      })

      // Reset the call count from any prior internal access during factory setup.
      clonedTrack.stop.mockClear()

      session.close()

      // Without the fix this assertion FAILS — pc.close() does not stop
      // the underlying MediaStreamTracks (only the source-side hardware
      // would be released if and only if no other clones exist).
      expect(clonedTrack.stop).toHaveBeenCalledTimes(1)
    })
  })
})
