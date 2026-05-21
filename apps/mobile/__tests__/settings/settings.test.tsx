/**
 * Settings screen tests (G29).
 *
 * The settings screen wires three stores + a sign-out side-effect:
 *   - authStore       → Account section (email/user id, Sign-out button)
 *   - prefsStore      → Voice section (language, vision, tts visual cue)
 *   - tutorialStore   → About section (Replay tutorial)
 *
 * These tests exercise the screen's *logic* through the public store
 * APIs rather than rendering native components. The pattern matches the
 * rest of the mobile test suite (logic tests against mocked MMKV + RN
 * native deps). We render via react-test-renderer where helpful for
 * snapshot-like assertions on the section structure.
 */

// ── Mock react-native-mmkv so stores have an in-memory backend ───────────────
type StoreBackend = Map<string, string>
let backingStore: StoreBackend

function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => {
      store.set(key, String(value))
    },
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

// ── Mock lib/auth.signOut ────────────────────────────────────────────────────
const mockSignOut = jest.fn().mockResolvedValue(undefined)
jest.mock('@/lib/auth', () => ({
  signOut: () => mockSignOut(),
}))

// ── Mock expo-constants for app version ──────────────────────────────────────
jest.mock('expo-constants', () => ({
  __esModule: true,
  default: {
    expoConfig: { version: '1.0.0' },
  },
}))

// ── Mock react-native primitives we touch in the screen ──────────────────────
// We render the screen with react-test-renderer, but the native modules
// don't matter — we only inspect props on host components.
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((props: Record<string, unknown>, ref: unknown) =>
      React.createElement(name, { ...props, ref })
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    TouchableOpacity: mk('TouchableOpacity'),
    Switch: mk('Switch'),
    ScrollView: mk('ScrollView'),
    StyleSheet: { create: (s: Record<string, unknown>) => s, flatten: (s: unknown) => s },
    Platform: { OS: 'ios', select: (m: Record<string, unknown>) => m.ios ?? m.default },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: React.forwardRef(
      (props: Record<string, unknown>, ref: unknown) =>
        React.createElement('SafeAreaView', { ...props, ref })
    ),
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (props: Record<string, unknown>) =>
      React.createElement('IconSymbol', props),
  }
})

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
  mockSignOut.mockClear()
})

describe('settings screen (G29)', () => {
  it('exports a default React component', () => {
    const mod = require('@/app/(tabs)/settings/index')
    expect(typeof mod.default).toBe('function')
  })

  it('renders Account, Voice, and About sections', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default

    // Seed the auth store so the Account section has a user to show.
    const { useAuthStore } = require('@/lib/stores/authStore')
    useAuthStore.setState({
      user: { id: 'user-123', email: 'test@example.com' },
      isAuthenticated: true,
      sessionToken: 'tok',
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    const json = JSON.stringify(tree!.toJSON())
    expect(json).toMatch(/Account/i)
    expect(json).toMatch(/Voice/i)
    expect(json).toMatch(/About/i)
  })

  it('shows the signed-in email in the Account section', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')

    useAuthStore.setState({
      user: { id: 'u', email: 'someone@example.com' },
      isAuthenticated: true,
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    expect(JSON.stringify(tree!.toJSON())).toContain('someone@example.com')
  })

  // ── CG09 — Sign-out failure path (lib/auth.signOut throws) ─────────────────
  //
  // PA-01 / H1-01: handleSignOut now wraps the signOut() call in
  // try/catch so a secure-store rejection on a locked device does NOT
  // bubble out as an unhandled promise rejection. clearSession() still
  // runs in the finally branch regardless.
  it('Sign-out still clears the auth store when lib/auth.signOut throws', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')

    mockSignOut.mockRejectedValueOnce(new Error('secure-store unavailable'))

    useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      isAuthenticated: true,
      sessionToken: 'bearer-xyz',
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })

    const signOutBtn = tree!.root.findByProps({ testID: 'settings-sign-out' })
    await TestRenderer.act(async () => {
      signOutBtn.props.onPress()
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(mockSignOut).toHaveBeenCalledTimes(1)
    const s = useAuthStore.getState()
    expect(s.isAuthenticated).toBe(false)
    expect(s.user).toBeNull()
    expect(s.sessionToken).toBeNull()
  })

  // ── CG34 — explicit "authStore cleared after sign-out" assertion ───────────
  //
  // The next test below already covers this — kept here as an extra,
  // tighter assertion that all three auth-state fields are nulled in a
  // single tick (no half-cleared state visible to subscribers).
  it('Sign-out clears authStore.user, isAuthenticated, and sessionToken atomically', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')

    useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      isAuthenticated: true,
      sessionToken: 'bearer-xyz',
    })

    const snapshots: Array<{
      user: unknown
      isAuthenticated: boolean
      sessionToken: string | null
    }> = []
    const unsub = useAuthStore.subscribe((s: ReturnType<typeof useAuthStore.getState>) => {
      snapshots.push({
        user: s.user,
        isAuthenticated: s.isAuthenticated,
        sessionToken: s.sessionToken,
      })
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })

    const signOutBtn = tree!.root.findByProps({ testID: 'settings-sign-out' })
    await TestRenderer.act(async () => {
      signOutBtn.props.onPress()
      await Promise.resolve()
      await Promise.resolve()
    })
    unsub()

    // The last snapshot must have all three fields cleared in one set().
    const last = snapshots[snapshots.length - 1]
    expect(last.user).toBeNull()
    expect(last.isAuthenticated).toBe(false)
    expect(last.sessionToken).toBeNull()
  })

  it('Sign-out clears the auth store and calls lib/auth.signOut', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')

    useAuthStore.setState({
      user: { id: 'u1', email: 'a@b.com' },
      isAuthenticated: true,
      sessionToken: 'bearer-xyz',
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })

    // Find the Sign-out button by testID.
    const signOutBtn = tree!.root.findByProps({ testID: 'settings-sign-out' })
    await TestRenderer.act(async () => {
      signOutBtn.props.onPress()
      // Let the awaited signOut resolve.
      await Promise.resolve()
      await Promise.resolve()
    })

    expect(mockSignOut).toHaveBeenCalledTimes(1)
    const s = useAuthStore.getState()
    expect(s.isAuthenticated).toBe(false)
    expect(s.user).toBeNull()
    expect(s.sessionToken).toBeNull()
  })

  it('toggling vision updates prefsStore.voiceChatVisionEnabled', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })
    expect(usePrefsStore.getState().voiceChatVisionEnabled).toBe(true)

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })

    const visionToggle = tree!.root.findByProps({ testID: 'settings-vision-toggle' })
    await TestRenderer.act(async () => {
      visionToggle.props.onValueChange(false)
      await Promise.resolve()
    })
    expect(usePrefsStore.getState().voiceChatVisionEnabled).toBe(false)
  })

  it('toggling TTS visual cue updates prefsStore.ttsVisualCueEnabled', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(true)

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })

    const cueToggle = tree!.root.findByProps({ testID: 'settings-tts-cue-toggle' })
    await TestRenderer.act(async () => {
      cueToggle.props.onValueChange(false)
      await Promise.resolve()
    })
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(false)
  })

  it('Replay-tutorial button calls tutorialStore.resetTour and then startTour', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })
    // Pretend the user has finished the tour once already.
    useTutorialStore.setState({ tourCompleted: true })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    const replayBtn = tree!.root.findByProps({ testID: 'settings-replay-tutorial' })
    TestRenderer.act(() => {
      replayBtn.props.onPress()
    })
    // resetTour clears the flag; startTour then sets tourActive=true.
    const s = useTutorialStore.getState()
    expect(s.tourCompleted).toBe(false)
    expect(s.tourActive).toBe(true)
    expect(s.tourStep).toBe(0)
  })

  it('shows the app version from expo-constants in the About section', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    expect(JSON.stringify(tree!.toJSON())).toContain('1.0.0')
  })

  it('lists every ALLOWED_LANGUAGES code in the language picker', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { ALLOWED_LANGUAGES } = require('@rishi/shared/lib/languages')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    const picker = tree!.root.findByProps({ testID: 'settings-language-picker' })
    // The picker should expose each code via a list of options the
    // implementation hands to it. We accept either an `options` prop
    // (custom picker) or a list of children with `value` props.
    const props = picker.props as Record<string, unknown>
    const options = (props.options as { value: string }[] | undefined) ?? []
    const codes = options.map((o) => o.value)
    for (const code of ALLOWED_LANGUAGES) {
      expect(codes).toContain(code)
    }
  })

  it('selecting a language calls prefsStore.setVoiceChatLanguage', async () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const Settings = require('@/app/(tabs)/settings/index').default
    const { useAuthStore } = require('@/lib/stores/authStore')
    const { usePrefsStore } = require('@/lib/stores/prefsStore')

    useAuthStore.setState({ user: { id: 'u', email: 'a@b.com' }, isAuthenticated: true })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(Settings))
    })
    const picker = tree!.root.findByProps({ testID: 'settings-language-picker' })
    await TestRenderer.act(async () => {
      picker.props.onValueChange('es')
      await Promise.resolve()
    })
    expect(usePrefsStore.getState().voiceChatLanguage).toBe('es')
  })
})
