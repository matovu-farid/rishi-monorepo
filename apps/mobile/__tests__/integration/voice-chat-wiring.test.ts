/**
 * T-P2.1 — WIRING-001 startup wiring integration test.
 *
 * Asserts that `apps/mobile/app/_layout.tsx` (or the dedicated startup
 * wiring module it imports) constructs the live mobile voice-chat service
 * and calls `setChatVoicePort(service)` exactly once after Better-Auth
 * session hydration completes, and never before.
 *
 * The wiring module under test does NOT yet exist — this test is RED until
 * `apps/mobile/lib/voice-chat/buildService.ts` is added AND `_layout.tsx`
 * subscribes to the auth store and calls `setChatVoicePort` per spec §3.9.
 *
 * Cases (per SPEC §3.9 acceptance criteria + PLAN T-P2.1):
 *   1. State A (unauthenticated): `setChatVoicePort` NOT called.
 *   2. State B (authenticated): `setChatVoicePort` called exactly once.
 *   3. Auth transition (null → authed): called exactly once after the
 *      transition, never before.
 *   4. Live event flow: an event fired through the service updates
 *      `useChatStore.getState().voiceState`.
 *
 * NOTE: The Hot-reload / Fast-Refresh idempotency case lives in the
 * `startupWiring` module-level guard. We test the public effect: a second
 * mount in State B does NOT call `setChatVoicePort` a second time.
 */

// ── Mock MMKV so authStore can be constructed in jest node env ──────────────
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const s = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        s.set(k, String(v))
      },
      getString: (k: string): string | undefined => s.get(k),
      remove: (k: string) => s.delete(k),
      getAllKeys: () => Array.from(s.keys()),
      clearAll: () => s.clear(),
    }
  },
}))

// ── Build a fake voice-chat service that matches the `VoiceChatPort`
//    surface in `lib/stores/chatStore.ts`. The factory under test
//    (`@/lib/voice-chat/buildService`) is mocked to return this instance
//    so the test never needs to drag react-native-webrtc / expo-audio
//    / shared `createVoiceChatService` into the node jest env. The
//    production factory's correctness is covered by the shared
//    voice-chat `service.test.ts` suite.
interface FakeService {
  activate: jest.Mock
  deactivate: jest.Mock
  getState: jest.Mock
  getError: jest.Mock
  dismissError: jest.Mock
  _stateListeners: Array<(state: string) => void>
  _statusListeners: Array<(status: string) => void>
  _endedByAgentListeners: Array<() => void>
  onStateChange: (cb: (state: string) => void) => () => void
  onChatStatus: (cb: (status: string) => void) => () => void
  onEndedByAgent: (cb: () => void) => () => void
}

function buildFakeService(): FakeService {
  const svc: FakeService = {
    activate: jest.fn().mockResolvedValue(undefined),
    deactivate: jest.fn(),
    getState: jest.fn().mockReturnValue('idle'),
    getError: jest.fn().mockReturnValue(null),
    dismissError: jest.fn(),
    _stateListeners: [],
    _statusListeners: [],
    _endedByAgentListeners: [],
    onStateChange(cb) {
      svc._stateListeners.push(cb)
      return () => undefined
    },
    onChatStatus(cb) {
      svc._statusListeners.push(cb)
      return () => undefined
    },
    onEndedByAgent(cb) {
      svc._endedByAgentListeners.push(cb)
      return () => undefined
    },
  }
  return svc
}

// MMKV is referenced transitively by authStore — keep it in-memory.
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const s = new Map<string, string>()
    return {
      set: (k: string, v: string) => {
        s.set(k, String(v))
      },
      getString: (k: string): string | undefined => s.get(k),
      remove: (k: string) => s.delete(k),
      getAllKeys: () => Array.from(s.keys()),
      clearAll: () => s.clear(),
    }
  },
}))

// authStore's `hydrateAuth` reads secure-store; we don't exercise that path,
// but the module is required transitively so stub it.
jest.mock('expo-secure-store', () => ({
  getItemAsync: jest.fn(async () => null),
  setItemAsync: jest.fn(async () => undefined),
  deleteItemAsync: jest.fn(async () => undefined),
}))
jest.mock('expo-web-browser', () => ({
  openAuthSessionAsync: jest.fn(),
  maybeCompleteAuthSession: jest.fn(),
}))
jest.mock('expo-crypto', () => ({}))
jest.mock('react-native-get-random-values', () => ({}), { virtual: true })

const nodeCrypto = require('node:crypto').webcrypto
if (!(globalThis as { crypto?: Crypto }).crypto) {
  ;(globalThis as { crypto?: Crypto }).crypto = nodeCrypto
}

/**
 * Helper that registers the virtual mock for the not-yet-implemented
 * `buildService` module AND a spy mock for `setChatVoicePort`, then
 * loads `startup-wiring` fresh. Returns handles to drive the test.
 *
 * Module isolation per `it` is achieved via `jest.isolateModules`. The
 * production `chatStore` is wrapped so the spy can observe every call
 * while still applying the real port wiring (so the live-event-flow
 * case sees real Zustand updates).
 */
function loadWithMocks() {
  const fakeService = buildFakeService()
  const buildMobileVoiceChatService = jest.fn(() => fakeService)
  const setChatVoicePortSpy = jest.fn()

  let handles: {
    runStartupWiring: () => void
    fakeService: FakeService
    buildMobileVoiceChatService: jest.Mock
    setChatVoicePortSpy: jest.Mock
    chatStore: typeof import('@/lib/stores/chatStore')
    authStore: typeof import('@/lib/stores/authStore')
  } | null = null

  jest.isolateModules(() => {
    // Mock for the buildService factory. Registered BEFORE
    // `startup-wiring` requires it so the resolver picks the mock —
    // `startup-wiring` lazy-requires `./buildService` inside `tryWire`
    // so this mock is consulted at call-time, not at module load.
    jest.doMock(
      '@/lib/voice-chat/buildService',
      () => ({ buildMobileVoiceChatService }),
    )

    // Wrap chatStore so setChatVoicePort is observable AND the real one
    // still runs (otherwise the event-flow test can't assert state).
    const realChatStore =
      jest.requireActual<typeof import('@/lib/stores/chatStore')>(
        '@/lib/stores/chatStore',
      )
    setChatVoicePortSpy.mockImplementation((p: unknown) =>
      realChatStore.setChatVoicePort(p as Parameters<typeof realChatStore.setChatVoicePort>[0]),
    )
    jest.doMock('@/lib/stores/chatStore', () => ({
      ...realChatStore,
      setChatVoicePort: setChatVoicePortSpy,
    }))

    // The not-yet-implemented startup-wiring module. The shape we expect:
    //   export function runStartupWiring(): void  // idempotent, subscribes
    //                                              // to authStore + wires
    //                                              // setChatVoicePort once.
    const wiring = require('@/lib/voice-chat/startup-wiring') as {
      runStartupWiring: () => void
    }

    handles = {
      runStartupWiring: wiring.runStartupWiring,
      fakeService,
      buildMobileVoiceChatService,
      setChatVoicePortSpy,
      chatStore: realChatStore,
      authStore: require('@/lib/stores/authStore'),
    }
  })

  if (!handles) throw new Error('isolateModules failed to populate handles')
  return handles
}

describe('WIRING-001 — startup voice-chat wiring (auth-gated)', () => {
  it('does NOT call setChatVoicePort when the user is unauthenticated (State A)', () => {
    const h = loadWithMocks()
    h.authStore.useAuthStore.setState({
      user: null,
      sessionToken: null,
      isAuthenticated: false,
    })

    h.runStartupWiring()

    expect(h.setChatVoicePortSpy).not.toHaveBeenCalled()
    expect(h.buildMobileVoiceChatService).not.toHaveBeenCalled()
  })

  it('calls setChatVoicePort exactly once when mounted in an authenticated state (State B)', () => {
    const h = loadWithMocks()
    h.authStore.useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      sessionToken: 'tok',
      isAuthenticated: true,
    })

    h.runStartupWiring()

    expect(h.buildMobileVoiceChatService).toHaveBeenCalledTimes(1)
    expect(h.setChatVoicePortSpy).toHaveBeenCalledTimes(1)
    expect(h.setChatVoicePortSpy.mock.calls[0]?.[0]).toBe(h.fakeService)
  })

  it('calls setChatVoicePort exactly once after a null → authed auth transition', () => {
    const h = loadWithMocks()
    h.authStore.useAuthStore.setState({
      user: null,
      sessionToken: null,
      isAuthenticated: false,
    })

    h.runStartupWiring()
    expect(h.setChatVoicePortSpy).not.toHaveBeenCalled()

    h.authStore.useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      sessionToken: 'tok',
      isAuthenticated: true,
    })

    expect(h.setChatVoicePortSpy).toHaveBeenCalledTimes(1)
    expect(h.buildMobileVoiceChatService).toHaveBeenCalledTimes(1)
  })

  it('does not double-wire when runStartupWiring is invoked twice while authed (Fast-Refresh idempotency)', () => {
    const h = loadWithMocks()
    h.authStore.useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      sessionToken: 'tok',
      isAuthenticated: true,
    })

    h.runStartupWiring()
    h.runStartupWiring()

    expect(h.setChatVoicePortSpy).toHaveBeenCalledTimes(1)
    expect(h.buildMobileVoiceChatService).toHaveBeenCalledTimes(1)
  })

  it('propagates live service events through chatStore.voiceState', () => {
    const h = loadWithMocks()
    h.authStore.useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      sessionToken: 'tok',
      isAuthenticated: true,
    })

    h.runStartupWiring()

    expect(h.fakeService._stateListeners.length).toBeGreaterThan(0)
    h.fakeService.getState.mockReturnValue('listening')
    for (const cb of h.fakeService._stateListeners) {
      cb('listening')
    }

    expect(h.chatStore.useChatStore.getState().voiceState).toBe('listening')
  })
})
