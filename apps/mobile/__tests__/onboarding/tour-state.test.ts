/**
 * Onboarding tour-state tests (G28).
 *
 * The tutorialStore (Batch 1B) already has a thorough behavioural test
 * suite — see `__tests__/stores/tutorialStore.test.ts`. This file
 * covers the new bridge code we add for G28:
 *
 *   - `registerTourTarget(id, layout)` / `unregisterTourTarget(id)`:
 *     mobile equivalent of electron's `[data-tour="…"]` selector. The
 *     spotlight overlay reads layouts out of this registry to draw
 *     itself around the right view.
 *   - `getTourTarget(id)` returns the most-recently-registered layout
 *     so the spotlight can read it during render.
 *
 * The registry is a plain in-memory module (no MMKV) because layouts
 * are render-time state and don't need to survive a reload.
 */

// ── MMKV mock so tutorialStore can hydrate from a backing map ───────────────
type StoreBackend = Map<string, string>
let backingStore: StoreBackend = new Map<string, string>()

jest.mock('react-native-mmkv', () => ({
  createMMKV: () => {
    const store = backingStore
    return {
      id: 'fake',
      set: (k: string, v: string) => {
        store.set(k, String(v))
      },
      getString: (k: string): string | undefined => store.get(k),
      remove: (k: string) => store.delete(k),
      getAllKeys: () => Array.from(store.keys()),
      clearAll: () => store.clear(),
    }
  },
}))

beforeEach(() => {
  jest.resetModules()
  backingStore = new Map<string, string>()
})

describe('tour target registry (G28)', () => {
  it('exports register/unregister/get/clear', () => {
    const mod = require('@/lib/onboarding/registry')
    expect(typeof mod.registerTourTarget).toBe('function')
    expect(typeof mod.unregisterTourTarget).toBe('function')
    expect(typeof mod.getTourTarget).toBe('function')
    expect(typeof mod.clearTourTargets).toBe('function')
  })

  it('returns undefined for an unknown target', () => {
    const { getTourTarget } = require('@/lib/onboarding/registry')
    expect(getTourTarget('does-not-exist')).toBeUndefined()
  })

  it('registers a layout and reads it back', () => {
    const {
      registerTourTarget,
      getTourTarget,
    } = require('@/lib/onboarding/registry')
    registerTourTarget('import-books', { x: 12, y: 24, width: 100, height: 44 })
    expect(getTourTarget('import-books')).toEqual({
      x: 12,
      y: 24,
      width: 100,
      height: 44,
    })
  })

  it('overwrites an existing layout for the same target', () => {
    const {
      registerTourTarget,
      getTourTarget,
    } = require('@/lib/onboarding/registry')
    registerTourTarget('book-grid', { x: 0, y: 0, width: 100, height: 100 })
    registerTourTarget('book-grid', { x: 5, y: 5, width: 200, height: 300 })
    expect(getTourTarget('book-grid')).toEqual({
      x: 5,
      y: 5,
      width: 200,
      height: 300,
    })
  })

  it('unregisterTourTarget removes the entry', () => {
    const {
      registerTourTarget,
      unregisterTourTarget,
      getTourTarget,
    } = require('@/lib/onboarding/registry')
    registerTourTarget('ai-chat', { x: 0, y: 0, width: 10, height: 10 })
    unregisterTourTarget('ai-chat')
    expect(getTourTarget('ai-chat')).toBeUndefined()
  })

  it('clearTourTargets wipes the whole registry', () => {
    const {
      registerTourTarget,
      getTourTarget,
      clearTourTargets,
    } = require('@/lib/onboarding/registry')
    registerTourTarget('a', { x: 0, y: 0, width: 1, height: 1 })
    registerTourTarget('b', { x: 0, y: 0, width: 1, height: 1 })
    clearTourTargets()
    expect(getTourTarget('a')).toBeUndefined()
    expect(getTourTarget('b')).toBeUndefined()
  })

  it('subscribes notify on changes (for re-render hooks)', () => {
    const {
      registerTourTarget,
      subscribeTourTargets,
    } = require('@/lib/onboarding/registry')
    const listener = jest.fn()
    const unsub = subscribeTourTargets(listener)
    registerTourTarget('import-books', { x: 0, y: 0, width: 1, height: 1 })
    expect(listener).toHaveBeenCalledTimes(1)
    unsub()
    registerTourTarget('book-grid', { x: 0, y: 0, width: 1, height: 1 })
    // After unsubscribe no more notifications.
    expect(listener).toHaveBeenCalledTimes(1)
  })
})

// ── CG25 — tour persistence across cold-start ───────────────────────────────
//
// Per prompt: "tour persist across cold-start". The tutorialStore only
// persists two keys into MMKV under `rishi.mobile.tutorial:`:
//   - `tour-completed`  ('1' iff the user has finished or skipped the tour)
//   - `hints-seen`      (JSON object of dismissed inline hints)
//
// `tourStep`, `tourActive`, and `tourPaused` are NOT persisted — the
// tour does not auto-resume mid-step. The contract is:
//   - Fresh install: tour starts on first dismissWelcome().
//   - User completes / skips: tour-completed=1 in MMKV.
//   - Next cold start: tutorialStore reads tour-completed=1, startTour()
//     is a no-op so the tour does NOT re-run.
//   - User taps "Replay tutorial" in Settings: resetTour() wipes the
//     flag, startTour() then runs the tour from step 0.
describe('CG25 — tutorial tour persistence across cold-start', () => {
  it('tour-completed flag persists across module reloads (cold-start sim)', () => {
    // First "boot": the user completes the tour.
    let { useTutorialStore } = require('@/lib/stores/tutorialStore')
    expect(useTutorialStore.getState().tourCompleted).toBe(false)
    useTutorialStore.getState().completeTour()
    expect(useTutorialStore.getState().tourCompleted).toBe(true)

    // Simulate cold-start: re-import the store module (state goes away,
    // but the backing MMKV map persists because it lives outside the
    // module scope).
    jest.resetModules()
    ;({ useTutorialStore } = require('@/lib/stores/tutorialStore'))

    // On re-hydration the store reads MMKV and finds tour-completed=1.
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
    // …and `startTour()` is a no-op because the tour is already done.
    useTutorialStore.getState().startTour()
    expect(useTutorialStore.getState().tourActive).toBe(false)
  })

  it('resetTour clears the persisted completion so the next cold-start runs the tour again', () => {
    let { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().completeTour()
    expect(backingStore.get('rishi.mobile.tutorial:tour-completed')).toBe('1')

    useTutorialStore.getState().resetTour()
    expect(backingStore.has('rishi.mobile.tutorial:tour-completed')).toBe(false)

    // Cold-start after reset — tourCompleted is false again, startTour
    // activates.
    jest.resetModules()
    ;({ useTutorialStore } = require('@/lib/stores/tutorialStore'))
    expect(useTutorialStore.getState().tourCompleted).toBe(false)
    useTutorialStore.getState().startTour()
    expect(useTutorialStore.getState().tourActive).toBe(true)
    expect(useTutorialStore.getState().tourStep).toBe(0)
  })

  it('hintsShown survives cold-start via the hints-seen MMKV key', () => {
    let { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().dismissHint('reader-toolbar')
    expect(useTutorialStore.getState().isHintSeen('reader-toolbar')).toBe(true)

    jest.resetModules()
    ;({ useTutorialStore } = require('@/lib/stores/tutorialStore'))
    expect(useTutorialStore.getState().isHintSeen('reader-toolbar')).toBe(true)
  })

  it('tourStep is NOT persisted — cold-start always returns to 0 (current contract)', () => {
    // This pins the EXISTING behaviour. The audit's CG19 row notes the
    // user-aspirational "resume mid-step" feature is not implemented;
    // a future change to that behaviour should update this test.
    let { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().startTour()
    useTutorialStore.getState().nextStep()
    expect(useTutorialStore.getState().tourStep).toBeGreaterThan(0)

    // Cold-start: tour-completed is still false (user didn't finish),
    // tourStep resets to 0, tour is inactive.
    jest.resetModules()
    ;({ useTutorialStore } = require('@/lib/stores/tutorialStore'))
    const s = useTutorialStore.getState()
    expect(s.tourCompleted).toBe(false)
    expect(s.tourStep).toBe(0)
    expect(s.tourActive).toBe(false)
  })
})
