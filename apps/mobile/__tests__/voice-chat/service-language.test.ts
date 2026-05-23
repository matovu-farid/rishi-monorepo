/**
 * CHT-024 — Mobile voice-chat service must re-read the voice-chat language
 * from the prefs store at activation time, not cache it at service
 * construction.
 *
 * Setup: stub the shared `createVoiceChatService` so we can inspect the
 * `getLanguage` function the mobile factory wires in. The real shared
 * service calls `getLanguage()` inside both the cold-activate and warm-
 * reactivate paths (see packages/shared/src/voice-chat/service.ts:69 +
 * :188). So as long as the mobile factory passes a function that reads
 * `usePrefsStore.getState().voiceChatLanguage` at call time, language
 * changes between activations are honored without remounting.
 *
 * Pinned behaviour (regression test for #67):
 *   1. Constructing the singleton with no `getLanguage` override still
 *      wires a function that reads `voiceChatLanguage` from `prefsStore`
 *      live — NOT the value at construction time.
 *   2. Mutating `usePrefsStore.getState().voiceChatLanguage` between
 *      activations is reflected on the next `getLanguage()` call.
 */

// ── Capture the deps the mobile factory passes to the shared service.
const capturedDeps: { getLanguage?: () => string } = {}
const fakeService = {
  start: jest.fn(),
  stop: jest.fn(),
  activate: jest.fn(),
  deactivate: jest.fn(),
  getState: () => 'idle',
  getError: () => null,
  dismissError: jest.fn(),
  dispose: jest.fn(),
  onStateChange: () => () => undefined,
  onChatStatus: () => () => undefined,
  onEndedByAgent: () => () => undefined,
}

jest.mock('@rishi/shared/voice-chat', () => ({
  createVoiceChatService: jest.fn((deps: { getLanguage: () => string }) => {
    capturedDeps.getLanguage = deps.getLanguage
    return fakeService
  }),
  createLocalVad: jest.fn(),
}))

// ── Stub out the mobile-side ports that service.ts pulls in. None of
//    them matter for this test — we only care that `getLanguage` reads
//    live from prefsStore.
jest.mock('@/lib/connectivity/MobileConnectivityPort', () => ({
  createMobileConnectivityPort: () => ({
    isOnline: () => true,
    subscribe: () => () => undefined,
  }),
}))
jest.mock('@/lib/voice-chat/media-port', () => ({
  mobileMediaPort: {},
}))
jest.mock('@/lib/voice-chat/ipc', () => ({
  mobileVoiceChatIpc: {},
}))
jest.mock('@/lib/voice-chat/realtime-session', () => ({
  mobileWebrtcFactory: jest.fn(),
  mobileAgentFactory: jest.fn(),
  mobileSessionFactory: jest.fn(),
}))
jest.mock('@/lib/voice-chat/sounds', () => ({
  getMobileEffectsPort: () => ({
    playReadyChime: jest.fn(),
    startThinkingSound: jest.fn(),
    stopThinkingSound: jest.fn(),
  }),
}))
jest.mock('@/lib/voice-chat/rag-port', () => ({
  createMobileRagPort: jest.fn(() => ({})),
}))

// ── A tiny prefsStore stub. We don't need the real Zustand store — just
//    a `getState()` that returns a mutable `voiceChatLanguage`.
const fakePrefsState: { voiceChatLanguage: string } = { voiceChatLanguage: 'en' }
jest.mock('@/lib/stores/prefsStore', () => ({
  usePrefsStore: {
    getState: () => fakePrefsState,
  },
}))

import {
  getVoiceChatService,
  _resetVoiceChatServiceForTests,
} from '@/lib/voice-chat/service'

describe('CHT-024 — voice-chat service language is read at activation time', () => {
  beforeEach(() => {
    _resetVoiceChatServiceForTests()
    capturedDeps.getLanguage = undefined
    fakePrefsState.voiceChatLanguage = 'en'
  })

  it('default getLanguage returns the CURRENT prefsStore value, not the construction-time value', () => {
    fakePrefsState.voiceChatLanguage = 'en'
    getVoiceChatService() // construct with default
    expect(capturedDeps.getLanguage).toBeDefined()

    // Initial read returns 'en'.
    expect(capturedDeps.getLanguage!()).toBe('en')

    // Settings change.
    fakePrefsState.voiceChatLanguage = 'es'

    // The very same getLanguage closure now returns the new value — i.e.
    // the service re-reads on every call, including the next activate.
    expect(capturedDeps.getLanguage!()).toBe('es')
  })

  it('honors an explicit getLanguage override when one is passed', () => {
    fakePrefsState.voiceChatLanguage = 'en'
    let langOverride = 'fr'
    getVoiceChatService({ getLanguage: () => langOverride })

    expect(capturedDeps.getLanguage!()).toBe('fr')

    langOverride = 'de'
    expect(capturedDeps.getLanguage!()).toBe('de')
  })

  it('singleton is preserved across calls — first opts still apply', () => {
    fakePrefsState.voiceChatLanguage = 'en'
    getVoiceChatService({ getLanguage: () => 'it' })
    // Second call with no opts: the singleton returns the first instance
    // and its getLanguage is the override from the first call.
    getVoiceChatService()
    expect(capturedDeps.getLanguage!()).toBe('it')
  })
})
