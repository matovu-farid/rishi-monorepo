/**
 * Phase 4 — ReaderOverlay (mobile).
 *
 * Pure orchestrator: based on `(isChatting, voiceActive, playingState)` it
 * mounts AIChatOrb / VoiceChatLauncher / MiniPlayer.
 *
 * Per ARCH §5 + UI-SPEC §9.4 the pinned behaviour (8 tests):
 *   1. Root carries `testID='reader-overlay'`.
 *   2. AIChatOrb mounted when `isChatting=true`.
 *   3. AIChatOrb absent when `isChatting=false`.
 *   4. VoiceChatLauncher ALWAYS mounted.
 *   5. MiniPlayer mounted when `!isChatting && playingState='playing'`.
 *   6. MiniPlayer hidden when `isChatting=true && playingState='playing'`.
 *   7. MiniPlayer hidden when `playingState='idle'`.
 *   8. `onChatToggle` prop is passed through to AIChatOrb's `onPress`.
 *
 * Mock strategy:
 *   - The 3 widget children (AIChatOrb, VoiceChatLauncher, MiniPlayer)
 *     are stubbed to host nodes that capture their props. This is the
 *     cleanest way to test orchestration without re-running each widget's
 *     own behaviour tests.
 *   - Both stores (chatStore, playerStore) are mocked with reassignable
 *     module-scoped state.
 *
 * Red signal: `@/components/reader/ReaderOverlay` does not exist yet.
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      absoluteFillObject: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  const passthrough = (v: unknown) => v
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    useReducedMotion: () => false,
    withTiming: passthrough,
    withSpring: passthrough,
    withDelay: (_d: number, v: unknown) => v,
    withSequence: (...vs: unknown[]) => vs,
    withRepeat: (v: unknown) => v,
    cancelAnimation: jest.fn(),
    Easing: {
      out: () => null,
      quad: null,
      inOut: () => null,
      linear: null,
    },
  }
})

// ── Stub the 3 child widgets so we can assert on the props ReaderOverlay
//    passes them, without re-rendering each widget. Virtual so the mock
//    path works even before the source modules land. ────────────────────────
jest.mock(
  '@/components/chat/AIChatOrb',
  () => {
    const React = require('react')
    const AIChatOrb = (p: any) =>
      React.createElement('AIChatOrbStub', { testID: 'ai-chat-orb-stub', ...p })
    return { __esModule: true, AIChatOrb }
  },
  { virtual: true },
)

jest.mock(
  '@/components/chat/VoiceChatLauncher',
  () => {
    const React = require('react')
    const VoiceChatLauncher = (p: any) =>
      React.createElement('VoiceChatLauncherStub', {
        testID: 'voice-chat-launcher-stub',
        ...p,
      })
    return { __esModule: true, VoiceChatLauncher }
  },
  { virtual: true },
)

jest.mock(
  '@/components/player/MiniPlayer',
  () => {
    const React = require('react')
    const MiniPlayer = (p: any) =>
      React.createElement('MiniPlayerStub', { testID: 'mini-player-stub', ...p })
    return { __esModule: true, MiniPlayer }
  },
  { virtual: true },
)

// ── chatStore selector mock ──────────────────────────────────────────────────
type ChatShape = {
  isChatting: boolean
  chatStatus: 'idle' | 'connecting' | 'thinking' | 'speaking'
  voiceState: 'idle' | 'connecting' | 'listening' | 'thinking' | 'speaking' | 'error'
  startChat: jest.Mock
  stopConversation: jest.Mock
}

const startChatMock = jest.fn()
const stopConversationMock = jest.fn()

let chatState: ChatShape = {
  isChatting: false,
  chatStatus: 'idle',
  voiceState: 'idle',
  startChat: startChatMock,
  stopConversation: stopConversationMock,
}

jest.mock('@/lib/stores/chatStore', () => ({
  __esModule: true,
  useChatStore: <T,>(selector: (s: ChatShape) => T) => selector(chatState),
}))

// ── playerStore selector mock ────────────────────────────────────────────────
type PlayerShape = {
  playingState: 'idle' | 'playing' | 'paused.clean' | 'loading'
  send: ((event: { type: string }) => void) | null
  repeatMode: 'off' | 'one'
}

let playerState: PlayerShape = {
  playingState: 'idle',
  send: () => undefined,
  repeatMode: 'off',
}

jest.mock('@/lib/stores/playerStore', () => ({
  __esModule: true,
  usePlayerStore: <T,>(selector: (s: PlayerShape) => T) => selector(playerState),
}))

// useRequireAuth → passthrough (calls action immediately).
jest.mock('@/components/auth/useRequireAuth', () => ({
  useRequireAuth: () => (action: () => void) => action(),
}))

// ── authStore selector mock — for P1-R (dismissedFeatures) + P1-T (isAuthenticated). ──
type AuthShape = {
  isAuthenticated: boolean
  dismissedFeatures: Set<string>
}
let authState: AuthShape = {
  isAuthenticated: false,
  dismissedFeatures: new Set<string>(),
}
jest.mock('@/lib/stores/authStore', () => ({
  __esModule: true,
  useAuthStore: <T,>(selector: (s: AuthShape) => T) => selector(authState),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ReaderOverlay } from '@/components/reader/ReaderOverlay'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

beforeEach(() => {
  startChatMock.mockClear()
  stopConversationMock.mockClear()
  chatState = {
    isChatting: false,
    chatStatus: 'idle',
    voiceState: 'idle',
    startChat: startChatMock,
    stopConversation: stopConversationMock,
  }
  playerState = {
    playingState: 'idle',
    send: () => undefined,
    repeatMode: 'off',
  }
  authState = {
    isAuthenticated: false,
    dismissedFeatures: new Set<string>(),
  }
})

describe('ReaderOverlay (mobile)', () => {
  it('renders a root node with testID="reader-overlay"', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'reader-overlay')).not.toBeNull()
  })

  it('mounts AIChatOrb when isChatting=true', () => {
    chatState.isChatting = true
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'ai-chat-orb-stub')).not.toBeNull()
  })

  it('does NOT mount AIChatOrb when isChatting=false', () => {
    chatState.isChatting = false
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'ai-chat-orb-stub')).toBeNull()
  })

  it('ALWAYS mounts VoiceChatLauncher', () => {
    chatState.isChatting = false
    playerState.playingState = 'idle'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'voice-chat-launcher-stub')).not.toBeNull()
    // Also true when chatting + playing.
    chatState.isChatting = true
    playerState.playingState = 'playing'
    let tree2!: TestRenderer.ReactTestRenderer
    act(() => {
      tree2 = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree2, 'voice-chat-launcher-stub')).not.toBeNull()
  })

  it('mounts MiniPlayer when !isChatting && playingState="playing"', () => {
    chatState.isChatting = false
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'mini-player-stub')).not.toBeNull()
  })

  it('does NOT mount MiniPlayer when isChatting=true && playingState="playing"', () => {
    chatState.isChatting = true
    playerState.playingState = 'playing'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'mini-player-stub')).toBeNull()
  })

  it('does NOT mount MiniPlayer when playingState="idle"', () => {
    chatState.isChatting = false
    playerState.playingState = 'idle'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'mini-player-stub')).toBeNull()
  })

  it('passes the activation context from getActivationContext into startChat (P0-O)', () => {
    chatState.isChatting = false
    const ctx = {
      pageText: 'Chapter 1',
      activeParagraphText: 'Some paragraph.',
      outline: [{ href: 'ch1', label: 'Chapter 1' }],
    }
    const getActivationContext = jest.fn(() => ctx)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderOverlay
          bookId="b1"
          getActivationContext={getActivationContext}
        />,
      )
    })
    const launcher = findByTestID(tree, 'voice-chat-launcher-stub')
    expect(launcher).not.toBeNull()
    const onStart = (launcher!.props as { onStart?: () => void }).onStart
    expect(typeof onStart).toBe('function')
    act(() => {
      onStart!()
    })
    expect(getActivationContext).toHaveBeenCalledTimes(1)
    expect(startChatMock).toHaveBeenCalledTimes(1)
    // second arg must be the gathered context (not an empty object)
    expect(startChatMock.mock.calls[0][1]).toEqual(ctx)
  })

  it("hides VoiceChatLauncher when voice-chat is in authStore.dismissedFeatures (P1-R)", () => {
    authState.isAuthenticated = false
    authState.dismissedFeatures = new Set(['voice-chat'])
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'voice-chat-launcher-stub')).toBeNull()
  })

  it("still renders VoiceChatLauncher when authenticated even if voice-chat is in dismissedFeatures (P1-R)", () => {
    // The set is only meant to hide the control while signed out. Once
    // the user signs in, the surface should always render the control.
    authState.isAuthenticated = true
    authState.dismissedFeatures = new Set(['voice-chat'])
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'voice-chat-launcher-stub')).not.toBeNull()
  })

  it('forwards onChatToggle to AIChatOrb as the onPress prop', () => {
    chatState.isChatting = true
    const onChatToggle = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ReaderOverlay bookId="b1" onChatToggle={onChatToggle} />,
      )
    })
    const orb = findByTestID(tree, 'ai-chat-orb-stub')
    expect(orb).not.toBeNull()
    const onPress = (orb!.props as { onPress?: () => void }).onPress
    expect(typeof onPress).toBe('function')
    onPress!()
    expect(onChatToggle).toHaveBeenCalledTimes(1)
  })
})
