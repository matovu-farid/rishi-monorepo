/**
 * Onboarding tour cold-start rehydration (CG19).
 *
 * The mobile tutorialStore is MMKV-backed. Only TWO keys are persisted:
 *   - tour-completed (whether the user finished/skipped the tour)
 *   - hints-seen     (dismissed hints map)
 *
 * `tourStep` itself is NOT persisted — that mirrors electron's
 * `apps/rishi-electron/.../tutorialStore.ts` (audited 2026-05-21).
 * On cold-start, tourStep ALWAYS starts at 0; if the user was mid-tour
 * when they killed the app, they restart from the beginning.
 *
 * These tests pin the cold-start contract so a future refactor doesn't
 * accidentally start persisting / hydrating `tourStep` without an
 * explicit electron-parity decision.
 */

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

describe('tutorialStore — cold-start rehydration (CG19)', () => {
  it('tourStep is NOT persisted: starts at 0 on cold-start even after advancing the tour', () => {
    // Simulate a session that advanced to step 2 then "killed" — i.e.
    // the backing store may carry whatever the live store persisted, but
    // we explicitly assert tourStep was NOT among the persisted keys.
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().startTour()
    useTutorialStore.getState().nextStep()
    useTutorialStore.getState().nextStep()
    expect(useTutorialStore.getState().tourStep).toBeGreaterThan(0)

    // No persisted key for tourStep.
    const tourStepKeys = Array.from(backingStore.keys()).filter((k) =>
      k.includes('tour-step'),
    )
    expect(tourStepKeys).toEqual([])

    // Cold-start by resetting jest modules with the SAME backing store.
    jest.resetModules()
    const { useTutorialStore: reloaded } = require('@/lib/stores/tutorialStore')
    expect(reloaded.getState().tourStep).toBe(0)
  })

  it('tourCompleted DOES survive cold-start (positive control)', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().skipTour()
    expect(useTutorialStore.getState().tourCompleted).toBe(true)

    // Cold-start.
    jest.resetModules()
    const { useTutorialStore: reloaded } = require('@/lib/stores/tutorialStore')
    expect(reloaded.getState().tourCompleted).toBe(true)
  })

  it('hintsShown DOES survive cold-start (positive control)', () => {
    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    useTutorialStore.getState().dismissHint('library-empty')
    useTutorialStore.getState().dismissHint('chat-tip')

    jest.resetModules()
    const { useTutorialStore: reloaded } = require('@/lib/stores/tutorialStore')
    expect(reloaded.getState().isHintSeen('library-empty')).toBe(true)
    expect(reloaded.getState().isHintSeen('chat-tip')).toBe(true)
    expect(reloaded.getState().isHintSeen('never-dismissed')).toBe(false)
  })

  it('startTour() is a no-op when tourCompleted was persisted true', () => {
    // Pre-populate MMKV as if the user finished the tour in a previous
    // session, then cold-start.
    backingStore.set('rishi.mobile.tutorial:tour-completed', '1')

    const { useTutorialStore } = require('@/lib/stores/tutorialStore')
    expect(useTutorialStore.getState().tourCompleted).toBe(true)

    useTutorialStore.getState().startTour()
    // Tour does NOT activate — the user has already seen it.
    expect(useTutorialStore.getState().tourActive).toBe(false)
    expect(useTutorialStore.getState().tourStep).toBe(0)
  })
})
