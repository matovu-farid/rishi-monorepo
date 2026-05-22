/**
 * Mobile voice-chat sound effects — defect P1-AJ.
 *
 * The 'thinking' state previously had a documented no-op for
 * startThinkingSound / stopThinkingSound. Users got no audible/haptic
 * cue while the model was preparing a reply, which on mobile is the only
 * channel that carries through with the screen locked. Electron parity
 * uses a Web Audio oscillator tick; mobile substitutes a periodic
 * `Haptics.selectionAsync` pulse so we don't have to ship an asset or
 * upgrade `react-native-worklets`.
 *
 * Behaviour pinned:
 *   1. `startThinkingSound()` schedules a recurring haptic via
 *      setInterval at ≤1500ms cadence and fires Haptics.selectionAsync
 *      on each tick.
 *   2. `stopThinkingSound()` clears the interval — no further haptics
 *      after stop.
 *   3. Calling start twice is idempotent (only one interval, no double-
 *      firing on each tick).
 */

// ── expo-audio + expo-file-system stubs ── (chime path is unrelated here).
jest.mock('expo-audio', () => ({
  createAudioPlayer: jest
    .fn()
    .mockReturnValue({ play: jest.fn(), remove: jest.fn(), volume: 1 }),
}), { virtual: true })

jest.mock('expo-file-system', () => ({
  File: jest
    .fn()
    .mockImplementation(() => ({ exists: true, uri: 'file:///chime.wav', write: jest.fn() })),
  Paths: { cache: 'file:///cache/' },
}), { virtual: true })

// ── expo-haptics spy.
const selectionAsync = jest.fn()
jest.mock('expo-haptics', () => ({
  selectionAsync,
  impactAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

import { createMobileEffectsPort } from '@/lib/voice-chat/sounds'

describe('mobile voice-chat sounds (P1-AJ: thinking haptic)', () => {
  beforeEach(() => {
    selectionAsync.mockClear()
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('fires Haptics.selectionAsync periodically while thinking', () => {
    const port = createMobileEffectsPort()
    port.startThinkingSound()

    // Cadence: <= 1500ms between ticks. Advance through three ticks.
    jest.advanceTimersByTime(1500)
    expect(selectionAsync).toHaveBeenCalledTimes(1)

    jest.advanceTimersByTime(1500)
    expect(selectionAsync).toHaveBeenCalledTimes(2)

    jest.advanceTimersByTime(1500)
    expect(selectionAsync).toHaveBeenCalledTimes(3)

    port.stopThinkingSound()
  })

  it('stopThinkingSound halts the haptic loop', () => {
    const port = createMobileEffectsPort()
    port.startThinkingSound()
    jest.advanceTimersByTime(1500)
    expect(selectionAsync).toHaveBeenCalledTimes(1)

    port.stopThinkingSound()
    jest.advanceTimersByTime(5000)
    // No additional ticks after stop.
    expect(selectionAsync).toHaveBeenCalledTimes(1)
  })

  it('startThinkingSound is idempotent — calling it twice does not double-tick', () => {
    const port = createMobileEffectsPort()
    port.startThinkingSound()
    port.startThinkingSound()

    jest.advanceTimersByTime(1500)
    expect(selectionAsync).toHaveBeenCalledTimes(1)

    port.stopThinkingSound()
  })
})
