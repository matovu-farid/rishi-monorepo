/**
 * Visual-cue store tests. The component (`<TTSVisualCue />`) is a thin
 * Pressable that reads from this store + prefsStore; the component
 * behaviour is exercised by the EPUB Maestro flow, not jest.
 */
jest.mock('react-native-mmkv', () => ({
  createMMKV: jest.fn(() => ({
    set: jest.fn(),
    getString: jest.fn(() => undefined),
    remove: jest.fn(),
    getAllKeys: jest.fn(() => []),
    clearAll: jest.fn(),
  })),
}))

import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { usePrefsStore } from '@/lib/stores/prefsStore'

describe('useVisualCueStore', () => {
  beforeEach(() => {
    useVisualCueStore.getState().clearVisualCue()
  })

  it('starts with no cue', () => {
    const s = useVisualCueStore.getState()
    expect(s.kind).toBeNull()
    expect(s.label).toBeNull()
    expect(s.target).toBeNull()
  })

  it('setVisualCue updates kind / label / target', () => {
    useVisualCueStore.getState().setVisualCue({
      kind: 'figure',
      label: 'Figure on page',
      target: 'fig-1',
    })
    const s = useVisualCueStore.getState()
    expect(s.kind).toBe('figure')
    expect(s.label).toBe('Figure on page')
    expect(s.target).toBe('fig-1')
  })

  it('setVisualCue(null) clears the cue', () => {
    useVisualCueStore.getState().setVisualCue({
      kind: 'equation',
      label: 'Equation on page',
    })
    useVisualCueStore.getState().setVisualCue(null)
    const s = useVisualCueStore.getState()
    expect(s.kind).toBeNull()
    expect(s.label).toBeNull()
  })

  it('clearVisualCue resets all three fields', () => {
    useVisualCueStore.getState().setVisualCue({
      kind: 'image',
      label: 'Image on page',
      target: 'img-1',
    })
    useVisualCueStore.getState().clearVisualCue()
    const s = useVisualCueStore.getState()
    expect(s.kind).toBeNull()
    expect(s.label).toBeNull()
    expect(s.target).toBeNull()
  })

  it('does not crash when partial cue is provided', () => {
    useVisualCueStore.getState().setVisualCue({ kind: 'equation' })
    const s = useVisualCueStore.getState()
    expect(s.kind).toBe('equation')
    expect(s.label).toBeNull()
    expect(s.target).toBeNull()
  })
})

describe('prefsStore.ttsVisualCueEnabled (Batch 1B field used by TTSVisualCue)', () => {
  it('defaults to true', () => {
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(true)
  })

  it('setTtsVisualCueEnabled(false) flips the flag', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(false)
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(false)
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
    expect(usePrefsStore.getState().ttsVisualCueEnabled).toBe(true)
  })
})
