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

// ── ReaderShellContext — provides `bottomBarVisible` so the overlay can
//    reflow its floating widgets when the reader bottom bar shows/hides
//    (P1-M). We expose the real React.Context so tests can wrap the tree
//    in a Provider to exercise both visibility states.
//
//    RDR-025 — the context was lifted into its own module
//    (`ReaderShellContext.tsx`) so leaf consumers don't pull in the full
//    reader stack. Mock both module paths so legacy import sites
//    (ReaderShell re-export) and new consumers (ReaderOverlay) share the
//    same context value. ───────────────────────────────────────────────────
const mockShellContextModule = (() => {
  const React = require('react')
  const ReaderShellContext = React.createContext({
    bottomBarVisible: false,
    toggleToolbar: () => undefined,
    interact: () => undefined,
  })
  return { ReaderShellContext }
})()
jest.mock('@/components/reader/ReaderShellContext', () => ({
  __esModule: true,
  ...mockShellContextModule,
}))
jest.mock('@/components/reader/ReaderShell', () => ({
  __esModule: true,
  ...mockShellContextModule,
}))

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

// @expo/vector-icons/Ionicons — LockChip uses it. ESM import must be
// stubbed for the node test VM.
jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

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

  describe('WGT-012 — orb mounts when chatStatus is non-idle even before isChatting flips', () => {
    // The chatPort can emit `chatStatus = 'connecting'` BEFORE
    // chatStore.startChat() flips `isChatting = true`. The previous
    // `isChatting ? <AIChatOrb /> : null` mount condition lost that first
    // frame; the user briefly saw no orb while the system was actually
    // already connecting. Mounting when EITHER signal is non-idle closes
    // the gap.
    it.each(['connecting', 'thinking', 'speaking'] as const)(
      'mounts AIChatOrb when isChatting=false but chatStatus="%s"',
      (status) => {
        chatState.isChatting = false
        chatState.chatStatus = status
        let tree!: TestRenderer.ReactTestRenderer
        act(() => {
          tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
        })
        expect(findByTestID(tree, 'ai-chat-orb-stub')).not.toBeNull()
      },
    )

    it('does NOT mount AIChatOrb when both isChatting=false and chatStatus="idle"', () => {
      chatState.isChatting = false
      chatState.chatStatus = 'idle'
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
      })
      expect(findByTestID(tree, 'ai-chat-orb-stub')).toBeNull()
    })
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

  it("renders a LockChip next to VoiceChatLauncher when not authenticated (P1-T)", () => {
    authState.isAuthenticated = false
    authState.dismissedFeatures = new Set<string>()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'voice-chat-launcher-stub')).not.toBeNull()
    expect(findByTestID(tree, 'voice-chat-lock-chip')).not.toBeNull()
  })

  it("does NOT render LockChip next to VoiceChatLauncher when authenticated (P1-T)", () => {
    authState.isAuthenticated = true
    authState.dismissedFeatures = new Set<string>()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    expect(findByTestID(tree, 'voice-chat-lock-chip')).toBeNull()
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

  it('uses tokens.zIndex.overlayChrome for AIChatOrb and VoiceChatLauncher (P1-M)', () => {
    // P1-M: floating widgets must not hardcode z-index values; they should
    // pull from the shared scale so they always stay above the toolbar
    // (zIndex.toolbar=10) and below sheets (zIndex.sheet=30).
    const { zIndex } = require('@/lib/theme/tokens') as {
      zIndex: { toolbar: number; overlayChrome: number; sheet: number }
    }
    chatState.isChatting = true
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<ReaderOverlay bookId="b1" />)
    })
    const orb = findByTestID(tree, 'ai-chat-orb-stub')
    expect(orb).not.toBeNull()
    expect((orb!.props as { style?: { zIndex?: number } }).style?.zIndex).toBe(
      zIndex.overlayChrome,
    )
    const launcher = findByTestID(tree, 'voice-chat-launcher-stub')
    expect(launcher).not.toBeNull()
    expect(
      (launcher!.props as { style?: { zIndex?: number } }).style?.zIndex,
    ).toBe(zIndex.overlayChrome)
  })

  it('reflows VoiceChatLauncher offset against bottomBarVisible (P1-M)', () => {
    // P1-M: the launcher must move up when the reader bottom bar is
    // visible — otherwise the bar (zIndex 10) renders directly under the
    // launcher (zIndex 20) and the two overlap visually. We exercise the
    // reflow by toggling the ReaderShellContext value the overlay reads.
    // RDR-025 — read from the lifted ReaderShellContext module. The
    // mock above re-exports the same Context from both module paths.
    const ReaderShell = require('@/components/reader/ReaderShellContext') as {
      ReaderShellContext: React.Context<{
        bottomBarVisible: boolean
        toggleToolbar: () => void
        interact: () => void
      }>
    }
    const Provider = ReaderShell.ReaderShellContext.Provider
    chatState.isChatting = false

    let treeHidden!: TestRenderer.ReactTestRenderer
    act(() => {
      treeHidden = TestRenderer.create(
        <Provider value={{ bottomBarVisible: false, toggleToolbar: () => undefined, interact: () => undefined }}>
          <ReaderOverlay bookId="b1" />
        </Provider>,
      )
    })
    const launcherHidden = findByTestID(treeHidden, 'voice-chat-launcher-stub')
    const bottomHidden = (
      launcherHidden!.props as { style?: { bottom?: number } }
    ).style?.bottom
    expect(typeof bottomHidden).toBe('number')

    let treeVisible!: TestRenderer.ReactTestRenderer
    act(() => {
      treeVisible = TestRenderer.create(
        <Provider value={{ bottomBarVisible: true, toggleToolbar: () => undefined, interact: () => undefined }}>
          <ReaderOverlay bookId="b1" />
        </Provider>,
      )
    })
    const launcherVisible = findByTestID(treeVisible, 'voice-chat-launcher-stub')
    const bottomVisible = (
      launcherVisible!.props as { style?: { bottom?: number } }
    ).style?.bottom
    expect(typeof bottomVisible).toBe('number')
    // When the bar is visible, the launcher must sit higher (larger bottom
    // offset) so it doesn't sit underneath the toolbar.
    expect(bottomVisible).toBeGreaterThan(bottomHidden as number)
  })

  it('lifts the launcher by 44 + insets.bottom when toolbar shows (WGT-016)', () => {
    // The previous constant `READER_BOTTOM_BAR_HEIGHT = 44` undercounted
    // the bar by `insets.bottom` (≈34pt on notched iPhones) because the
    // bottom-variant Toolbar pads its own bottom by insets.bottom. The
    // floating widgets must lift by the REAL height — 44 + insets.bottom
    // — or they sit underneath the toolbar.
    // useSafeAreaInsets is mocked above with bottom: 34.
    const ReaderShell = require('@/components/reader/ReaderShellContext') as {
      ReaderShellContext: React.Context<{
        bottomBarVisible: boolean
        toggleToolbar: () => void
        interact: () => void
      }>
    }
    const Provider = ReaderShell.ReaderShellContext.Provider
    chatState.isChatting = false

    let treeHidden!: TestRenderer.ReactTestRenderer
    act(() => {
      treeHidden = TestRenderer.create(
        <Provider value={{ bottomBarVisible: false, toggleToolbar: () => undefined, interact: () => undefined }}>
          <ReaderOverlay bookId="b1" />
        </Provider>,
      )
    })
    const bottomHidden = (
      findByTestID(treeHidden, 'voice-chat-launcher-stub')!.props as {
        style?: { bottom?: number }
      }
    ).style?.bottom as number

    let treeVisible!: TestRenderer.ReactTestRenderer
    act(() => {
      treeVisible = TestRenderer.create(
        <Provider value={{ bottomBarVisible: true, toggleToolbar: () => undefined, interact: () => undefined }}>
          <ReaderOverlay bookId="b1" />
        </Provider>,
      )
    })
    const bottomVisible = (
      findByTestID(treeVisible, 'voice-chat-launcher-stub')!.props as {
        style?: { bottom?: number }
      }
    ).style?.bottom as number

    expect(bottomVisible - bottomHidden).toBe(44 + 34)
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
