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

beforeEach(() => {
  jest.resetModules()
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
