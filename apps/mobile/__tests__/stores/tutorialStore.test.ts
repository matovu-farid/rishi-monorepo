/**
 * Tests for the mobile tutorialStore (ported from electron).
 *
 * Same behavioural contract as electron, but persisted to MMKV via
 * `lib/storage/mmkv.ts`. We use the in-memory fallback in tests by
 * mocking `react-native-mmkv`.
 */

// ── Mock react-native-mmkv so the adapter runs against an in-memory shim ──
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

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
})

describe('tutorialStore (mobile)', () => {
  it('TOUR_STEPS is exported with at least the electron-baseline 3 steps', () => {
    const { TOUR_STEPS } = require('@/lib/stores/tutorialStore')
    expect(Array.isArray(TOUR_STEPS)).toBe(true)
    expect(TOUR_STEPS.length).toBeGreaterThanOrEqual(3)
  })

  it('defaults: tour inactive, step 0, not completed, no hints seen', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    const s = useTutorialStore.getState()
    expect(s.tourActive).toBe(false)
    expect(s.tourStep).toBe(0)
    expect(s.tourCompleted).toBe(false)
    expect(s.tourPaused).toBe(false)
    expect(s.hintsShown).toEqual({})
  })

  it('startTour() flips tourActive=true and resets step to 0', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.setState({ tourActive: false, tourStep: 5, tourPaused: true })
    useTutorialStore.getState().startTour()
    const s = useTutorialStore.getState()
    expect(s.tourActive).toBe(true)
    expect(s.tourStep).toBe(0)
    expect(s.tourPaused).toBe(false)
  })

  it('startTour() is a no-op when tourCompleted is true', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.setState({ tourCompleted: true })
    useTutorialStore.getState().startTour()
    expect(useTutorialStore.getState().tourActive).toBe(false)
  })

  it('nextStep advances tourStep by 1 within range', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.setState({ tourActive: true, tourStep: 0 })
    useTutorialStore.getState().nextStep()
    expect(useTutorialStore.getState().tourStep).toBe(1)
  })

  it('nextStep at the last step completes the tour', () => {
    const { useTutorialStore, TOUR_STEPS } = require('@/lib/stores/tutorialStore')
    useTutorialStore.setState({ tourActive: true, tourStep: TOUR_STEPS.length - 1 })
    useTutorialStore.getState().nextStep()
    const s = useTutorialStore.getState()
    expect(s.tourCompleted).toBe(true)
    expect(s.tourActive).toBe(false)
  })

  it('skipTour() marks tour completed and persists the flag', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().skipTour()
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
    // Persisted to the bucketed key
    const persisted = Array.from(backingStore.entries()).find(
      ([k]) => k.endsWith(':tour-completed'),
    )
    expect(persisted?.[1]).toBe('1')
  })

  it('resetTour() clears completion + hints, removes persisted keys', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().dismissHint('h-1')
    useTutorialStore.getState().skipTour()
    useTutorialStore.getState().resetTour()
    const s = useTutorialStore.getState()
    expect(s.tourCompleted).toBe(false)
    expect(s.hintsShown).toEqual({})
    // Persisted keys removed
    const hasTourKey = Array.from(backingStore.keys()).some((k) => k.endsWith(':tour-completed'))
    const hasHintsKey = Array.from(backingStore.keys()).some((k) => k.endsWith(':hints-seen'))
    expect(hasTourKey).toBe(false)
    expect(hasHintsKey).toBe(false)
  })

  it('dismissHint persists the hints-seen map and isHintSeen reflects it', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().dismissHint('intro-tip')
    expect(useTutorialStore.getState().isHintSeen('intro-tip')).toBe(true)
    expect(useTutorialStore.getState().isHintSeen('other-tip')).toBe(false)
    const persistedEntry = Array.from(backingStore.entries()).find(
      ([k]) => k.endsWith(':hints-seen'),
    )
    expect(persistedEntry).toBeDefined()
    expect(JSON.parse(persistedEntry![1])).toEqual({ 'intro-tip': true })
  })

  it('pauseTour / resumeTour toggle the tourPaused flag', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().pauseTour()
    expect(useTutorialStore.getState().tourPaused).toBe(true)
    useTutorialStore.getState().resumeTour()
    expect(useTutorialStore.getState().tourPaused).toBe(false)
  })

  it('initial state hydrates tourCompleted from persisted MMKV value', () => {
    // Pre-populate the backing store BEFORE the module is loaded.
    backingStore.set('rishi.mobile.tutorial:tour-completed', '1')
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
  })
})
