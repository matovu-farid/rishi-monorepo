/**
 * Tests for the realtime voice session module.
 * Covers: session creation, WebRTC setup, tool call dispatch,
 * microphone permission handling, and session teardown.
 */

// ── Mock react-native-webrtc ────────────────────────────────────────────────
const mockAddTrack = jest.fn()
const mockCreateOffer = jest.fn().mockResolvedValue({ type: 'offer', sdp: 'v=0\r\no=- mock-sdp' })
const mockSetLocalDescription = jest.fn().mockResolvedValue(undefined)
const mockSetRemoteDescription = jest.fn().mockResolvedValue(undefined)
const mockClosePC = jest.fn()

let dcOnOpen: (() => void) | null = null
let dcOnMessage: ((event: { data: string }) => void) | null = null
const mockDcSend = jest.fn()
const mockDcClose = jest.fn()

const mockDataChannel = {
  send: mockDcSend,
  close: mockDcClose,
  addEventListener(event: string, fn: (...args: any[]) => void) {
    if (event === 'open') dcOnOpen = fn
    if (event === 'message') dcOnMessage = fn as (event: { data: string }) => void
  },
}

const mockCreateDataChannel = jest.fn().mockReturnValue(mockDataChannel)
const mockGetUserMedia = jest.fn().mockResolvedValue({
  getTracks: () => [{ stop: jest.fn(), kind: 'audio' }],
})

jest.mock('react-native-webrtc', () => ({
  RTCPeerConnection: jest.fn().mockImplementation(() => ({
    createDataChannel: mockCreateDataChannel,
    addTrack: mockAddTrack,
    createOffer: mockCreateOffer,
    setLocalDescription: mockSetLocalDescription,
    setRemoteDescription: mockSetRemoteDescription,
    close: mockClosePC,
  })),
  mediaDevices: {
    getUserMedia: mockGetUserMedia,
  },
}), { virtual: true })

// ── Mock react-native ───────────────────────────────────────────────────────
const mockPermissionRequest = jest.fn().mockResolvedValue('granted')

jest.mock('react-native', () => ({
  Platform: { OS: 'android' },
  PermissionsAndroid: {
    request: mockPermissionRequest,
    PERMISSIONS: { RECORD_AUDIO: 'android.permission.RECORD_AUDIO' },
    RESULTS: { GRANTED: 'granted', DENIED: 'denied' },
  },
}), { virtual: true })

// ── Mock @/lib/api ──────────────────────────────────────────────────────────
const mockApiClient = jest.fn().mockResolvedValue({
  ok: true,
  json: async () => ({ client_secret: { value: 'test-ephemeral-key' } }),
})
jest.mock('@/lib/api', () => ({
  apiClient: mockApiClient,
}))

// ── Mock @/lib/rag/vector-store ─────────────────────────────────────────────
const mockSearchSimilarChunks = jest.fn().mockReturnValue([
  { id: 'c1', text: 'chunk1 text', distance: 0.1, chapter: 'Ch1', chunkIndex: 0 },
])
jest.mock('@/lib/rag/vector-store', () => ({
  searchSimilarChunks: mockSearchSimilarChunks,
}))

// ── Mock @/lib/rag/embedder ─────────────────────────────────────────────────
const mockEmbedBatch = jest.fn().mockResolvedValue([[0.1, 0.2, 0.3]])
const mockIsEmbeddingReady = jest.fn().mockReturnValue(true)
jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: mockEmbedBatch,
  isEmbeddingReady: mockIsEmbeddingReady,
}))

// ── Mock @/lib/rag/server-fallback ──────────────────────────────────────────
const mockEmbedTextsOnServer = jest.fn().mockResolvedValue([[0.4, 0.5, 0.6]])
jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: mockEmbedTextsOnServer,
}))

// ── Mock ./guardrails ───────────────────────────────────────────────────────
jest.mock('@/lib/realtime/guardrails', () => ({
  checkGuardrail: jest.fn().mockResolvedValue(false),
}))

// ── Mock global fetch (for SDP exchange) ────────────────────────────────────
const originalFetch = global.fetch
beforeAll(() => {
  global.fetch = jest.fn().mockResolvedValue({
    ok: true,
    text: async () => 'v=0\r\no=- answer-sdp',
  }) as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = originalFetch
})

// ── Import after mocks ─────────────────────────────────────────────────────
import { createRealtimeSession, closeRealtimeSession } from '@/lib/realtime/session'

describe('realtime session', () => {
  let mockTrackStop: jest.Mock

  beforeEach(() => {
    jest.clearAllMocks()
    mockPermissionRequest.mockResolvedValue('granted')
    mockTrackStop = jest.fn()
    const tracks = [{ stop: mockTrackStop, kind: 'audio' }]
    mockGetUserMedia.mockResolvedValue({
      getTracks: () => tracks,
    })
    dcOnOpen = null
    dcOnMessage = null
  })

  // Test 1: createRealtimeSession calls apiClient for ephemeral key
  it('calls apiClient to get ephemeral key', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(mockApiClient).toHaveBeenCalledWith('/api/realtime/client_secrets')
  })

  // Test 2: creates RTCPeerConnection and data channel named 'oai-events'
  it('creates RTCPeerConnection and data channel', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(mockCreateDataChannel).toHaveBeenCalledWith('oai-events')
  })

  // Test 3: adds local audio track from getUserMedia
  it('adds local audio track from getUserMedia', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(mockGetUserMedia).toHaveBeenCalledWith({ audio: true })
    expect(mockAddTrack).toHaveBeenCalled()
  })

  // Test 4: sends SDP offer to OpenAI and sets remote description
  it('sends SDP offer and sets remote description', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(mockCreateOffer).toHaveBeenCalled()
    expect(mockSetLocalDescription).toHaveBeenCalled()
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining('api.openai.com/v1/realtime'),
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: 'Bearer test-ephemeral-key',
          'Content-Type': 'application/sdp',
        }),
      })
    )
    expect(mockSetRemoteDescription).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'answer', sdp: 'v=0\r\no=- answer-sdp' })
    )
  })

  // Test 5: on data channel open, session.update is sent with tools and instructions
  it('sends session.update with tools on data channel open', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(dcOnOpen).toBeTruthy()
    dcOnOpen!()

    const sessionUpdateCall = mockDcSend.mock.calls.find((call: unknown[]) => {
      const parsed = JSON.parse(call[0] as string)
      return parsed.type === 'session.update'
    })
    expect(sessionUpdateCall).toBeTruthy()
    const msg = JSON.parse(sessionUpdateCall![0] as string)
    expect(msg.session.tools).toBeDefined()
    expect(msg.session.tools.length).toBe(2)
    expect(msg.session.instructions).toBeDefined()
  })

  // Test 6: on data channel open, initial greeting message and response.create are sent
  it('sends initial greeting and response.create on dc open', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    dcOnOpen!()

    const calls = mockDcSend.mock.calls.map((c: unknown[]) => JSON.parse(c[0] as string))
    const greetingMsg = calls.find(
      (c: { type: string }) => c.type === 'conversation.item.create'
    )
    expect(greetingMsg).toBeTruthy()
    expect(greetingMsg.item.content[0].text).toContain('greet the user')

    const responseCreate = calls.find((c: { type: string }) => c.type === 'response.create')
    expect(responseCreate).toBeTruthy()
  })

  // Test 7: bookContext tool call embeds query and searches chunks
  it('handles bookContext tool call with RAG pipeline', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(dcOnMessage).toBeTruthy()

    dcOnMessage!({
      data: JSON.stringify({
        type: 'response.function_call_arguments.done',
        name: 'bookContext',
        call_id: 'call-123',
        arguments: JSON.stringify({ queryText: 'What is the theme?' }),
      }),
    })

    await new Promise(resolve => setTimeout(resolve, 50))

    expect(mockEmbedBatch).toHaveBeenCalledWith(['What is the theme?'])
    expect(mockSearchSimilarChunks).toHaveBeenCalledWith('book-1', [0.1, 0.2, 0.3], 3)

    const outputCall = mockDcSend.mock.calls.find((call: unknown[]) => {
      const parsed = JSON.parse(call[0] as string)
      return parsed.type === 'conversation.item.create' && parsed.item?.type === 'function_call_output'
    })
    expect(outputCall).toBeTruthy()
  })

  // Test 8: endConversation tool call closes session
  it('handles endConversation tool call', async () => {
    const onSessionEnded = jest.fn()
    await createRealtimeSession({ bookId: 'book-1', onSessionEnded })

    dcOnMessage!({
      data: JSON.stringify({
        type: 'response.function_call_arguments.done',
        name: 'endConversation',
        call_id: 'call-456',
        arguments: JSON.stringify({ reason: 'User said goodbye' }),
      }),
    })

    await new Promise(resolve => setTimeout(resolve, 50))

    expect(onSessionEnded).toHaveBeenCalled()
  })

  // Test 9: closeRealtimeSession stops tracks and closes peer connection
  it('closes session: stops tracks and closes PC', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    closeRealtimeSession()

    expect(mockTrackStop).toHaveBeenCalled()
    expect(mockDcClose).toHaveBeenCalled()
    expect(mockClosePC).toHaveBeenCalled()
  })

  // Test 10: on Android, PermissionsAndroid.request is called before getUserMedia
  it('requests RECORD_AUDIO permission on Android before getUserMedia', async () => {
    await createRealtimeSession({ bookId: 'book-1' })

    expect(mockPermissionRequest).toHaveBeenCalledWith(
      'android.permission.RECORD_AUDIO',
      expect.objectContaining({ title: 'Microphone Permission' })
    )

    // Verify getUserMedia was called after permission
    const permCallOrder = mockPermissionRequest.mock.invocationCallOrder[0]
    const mediaCallOrder = mockGetUserMedia.mock.invocationCallOrder[0]
    expect(permCallOrder).toBeLessThan(mediaCallOrder)
  })

  // Test 11: if Android permission denied, throws without calling getUserMedia
  it('throws if Android microphone permission denied', async () => {
    mockPermissionRequest.mockResolvedValue('denied')

    await expect(
      createRealtimeSession({ bookId: 'book-1' })
    ).rejects.toThrow('Microphone permission denied')

    expect(mockGetUserMedia).not.toHaveBeenCalled()
  })
})
