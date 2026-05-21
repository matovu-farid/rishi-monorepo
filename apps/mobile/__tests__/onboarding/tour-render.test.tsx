/**
 * Onboarding tour render tests (G28).
 *
 * Renders the `<TourProvider />` component through 3 steps and asserts:
 *   - Step 1 (`import-books`) shows the right title/description.
 *   - "Next" advances the store's `tourStep`.
 *   - At the last step, "Done" calls `completeTour()`.
 *   - "Skip" calls `skipTour()`.
 *
 * Renders host components are mocked the same way the settings tests
 * mock them — react-test-renderer with stubbed `react-native` primitives.
 */

// ── Mock MMKV (tutorialStore reads it on init) ───────────────────────────────
type StoreBackend = Map<string, string>
let backingStore: StoreBackend
function buildFakeMMKV() {
  const store = backingStore
  return {
    id: 'fake',
    set: (key: string, value: string) => store.set(key, String(value)),
    getString: (key: string): string | undefined => store.get(key),
    remove: (key: string) => store.delete(key),
    getAllKeys: () => Array.from(store.keys()),
    clearAll: () => store.clear(),
  }
}
jest.mock('react-native-mmkv', () => ({
  createMMKV: () => buildFakeMMKV(),
}))

// ── Mock react-native primitives ─────────────────────────────────────────────
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
    Dimensions: { get: () => ({ width: 390, height: 844 }) },
    StyleSheet: { create: (s: Record<string, unknown>) => s, absoluteFillObject: {} },
  }
})

// Reanimated mock — we don't need real animations for the test;
// just want the wrapper component to render its children.
jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = (props: Record<string, unknown>) =>
    React.createElement('Animated.View', props)
  return {
    __esModule: true,
    default: { View },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    withTiming: (v: unknown) => v,
    withSpring: (v: unknown) => v,
  }
})

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
})

describe('TourProvider (G28)', () => {
  it('renders nothing when tour is inactive', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    expect(tree!.toJSON()).toBeNull()
  })

  it('renders step 1 title/description when tourActive=true', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    const {
      registerTourTarget,
    } = require('@/lib/onboarding/registry')

    // Register a layout for step 1's target so the overlay has
    // something to spotlight.
    registerTourTarget('import-books', { x: 10, y: 10, width: 100, height: 50 })

    useTutorialStore.setState({ tourActive: true, tourStep: 0, tourPaused: false })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    const json = JSON.stringify(tree!.toJSON())
    expect(json).toMatch(/Add Your Books/)
    expect(json).toMatch(/Tap here to add books/)
  })

  it('Next button advances to step 2', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    const {
      registerTourTarget,
    } = require('@/lib/onboarding/registry')

    registerTourTarget('import-books', { x: 0, y: 0, width: 1, height: 1 })
    registerTourTarget('book-grid', { x: 0, y: 0, width: 1, height: 1 })

    useTutorialStore.setState({ tourActive: true, tourStep: 0, tourPaused: false })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    const nextBtn = tree!.root.findByProps({ testID: 'tour-next' })
    TestRenderer.act(() => {
      nextBtn.props.onPress()
    })
    expect(useTutorialStore.getState().tourStep).toBe(1)
  })

  it('Skip button calls skipTour and marks completed', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    const {
      registerTourTarget,
    } = require('@/lib/onboarding/registry')

    registerTourTarget('import-books', { x: 0, y: 0, width: 1, height: 1 })
    useTutorialStore.setState({ tourActive: true, tourStep: 0, tourPaused: false })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    const skipBtn = tree!.root.findByProps({ testID: 'tour-skip' })
    TestRenderer.act(() => {
      skipBtn.props.onPress()
    })
    const s = useTutorialStore.getState()
    expect(s.tourActive).toBe(false)
    expect(s.tourCompleted).toBe(true)
  })

  it('final step Next button completes the tour', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore, TOUR_STEPS } = require('@/lib/stores/tutorialStore')
    const {
      registerTourTarget,
    } = require('@/lib/onboarding/registry')

    // Register every step's target so the renderer doesn't bail.
    for (const step of TOUR_STEPS) {
      registerTourTarget(step.target, { x: 0, y: 0, width: 1, height: 1 })
    }

    useTutorialStore.setState({
      tourActive: true,
      tourStep: TOUR_STEPS.length - 1,
      tourPaused: false,
    })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    const nextBtn = tree!.root.findByProps({ testID: 'tour-next' })
    TestRenderer.act(() => {
      nextBtn.props.onPress()
    })
    expect(useTutorialStore.getState().tourActive).toBe(false)
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
  })

  it('renders the step counter (e.g. "1 of 3")', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore, TOUR_STEPS } = require('@/lib/stores/tutorialStore')
    const {
      registerTourTarget,
    } = require('@/lib/onboarding/registry')

    for (const step of TOUR_STEPS) {
      registerTourTarget(step.target, { x: 0, y: 0, width: 1, height: 1 })
    }
    useTutorialStore.setState({ tourActive: true, tourStep: 0, tourPaused: false })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    const json = JSON.stringify(tree!.toJSON())
    // React renders mixed text children as separate strings — e.g.
    // ["1", " of ", "3"]. Assert each piece individually.
    expect(json).toContain('"1"')
    expect(json).toContain('" of "')
    expect(json).toContain(`"${TOUR_STEPS.length}"`)
  })

  it('skips rendering when the target layout is unknown (waits for layout)', () => {
    const TestRenderer = require('react-test-renderer')
    const React = require('react')
    const { TourProvider } = require('@/components/onboarding/TourProvider')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')

    // Activate the tour WITHOUT registering any targets.
    useTutorialStore.setState({ tourActive: true, tourStep: 0, tourPaused: false })

    let tree: ReturnType<typeof TestRenderer.create> | null = null
    TestRenderer.act(() => {
      tree = TestRenderer.create(React.createElement(TourProvider))
    })
    // Without a known target layout the overlay should render nothing
    // (or a tooltip-only fallback). We accept either, but the tour-next
    // button must not be visible — otherwise a tap would advance the
    // step without the user ever seeing the target.
    expect(() => tree!.root.findByProps({ testID: 'tour-next' })).toThrow()
  })
})
