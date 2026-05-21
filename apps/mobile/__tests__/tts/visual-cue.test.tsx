/**
 * G15 — TTSVisualCue render behaviour.
 *
 * The component is gated on prefsStore.ttsVisualCueEnabled AND on a
 * non-null cue in visualCueStore. We exercise both gates plus the
 * "renders with the right accessibility label" path used by the
 * onboarding tour + screen readers.
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

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((props: Record<string, unknown>, ref: unknown) =>
      React.createElement(name, { ...props, ref }),
    )
  return {
    Pressable: mk('Pressable'),
    Text: mk('Text'),
    View: mk('View'),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      flatten: (s: unknown) => s,
    },
  }
})

import React from 'react'
import TestRenderer, { act } from 'react-test-renderer'
import { TTSVisualCue } from '@/components/TTSVisualCue'
import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { usePrefsStore } from '@/lib/stores/prefsStore'

function findByTestID(tree: TestRenderer.ReactTestRenderer, testID: string) {
  try {
    return tree.root.findByProps({ testID })
  } catch {
    return null
  }
}

describe('TTSVisualCue render gates', () => {
  beforeEach(() => {
    useVisualCueStore.getState().clearVisualCue()
  })

  it('renders nothing when enabled=true but no cue is set', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TTSVisualCue />)
    })
    expect(tree.toJSON()).toBeNull()
    act(() => tree.unmount())
  })

  it('renders nothing when ttsVisualCueEnabled is false even with a cue set', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(false)
    act(() => {
      useVisualCueStore.getState().setVisualCue({
        kind: 'equation',
        label: 'Equation on page',
      })
    })

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TTSVisualCue />)
    })
    expect(tree.toJSON()).toBeNull()
    act(() => tree.unmount())

    // restore
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
  })

  it('renders the label when enabled=true and a cue is set', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
    act(() => {
      useVisualCueStore.getState().setVisualCue({
        kind: 'figure',
        label: 'Figure on page',
        target: 'fig-1',
      })
    })

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TTSVisualCue />)
    })
    expect(tree.toJSON()).not.toBeNull()
    const button = findByTestID(tree, 'tts-visual-cue')
    expect(button).not.toBeNull()
    expect(button!.props.accessibilityLabel).toBe('Figure on page')
    act(() => tree.unmount())
  })

  it('invokes onPress with target when tapped', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
    act(() => {
      useVisualCueStore.getState().setVisualCue({
        kind: 'equation',
        label: 'Equation on page',
        target: 'eq-7',
      })
    })

    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TTSVisualCue onPress={onPress} />)
    })
    const button = findByTestID(tree, 'tts-visual-cue')!
    act(() => {
      button.props.onPress()
    })
    expect(onPress).toHaveBeenCalledWith('eq-7')
    act(() => tree.unmount())
  })
})

// ── Reader-screen mount assertions ───────────────────────────────────────────
//
// G15 also requires that each reader screen mounts <TTSVisualCue />. We do a
// source-level check here for the same reason as the chat-bridge wiring
// assertions — avoids pulling in the full reader native deps.

import { readFileSync } from 'fs'
import { join } from 'path'

const READER_FILES = [
  'app/reader/[id].tsx',
  'app/reader/pdf/[id].tsx',
  'app/reader/mobi/[id].tsx',
  'app/reader/djvu/[id].tsx',
]

describe('Reader screens mount <TTSVisualCue /> (G15)', () => {
  for (const rel of READER_FILES) {
    it(`${rel} imports and renders TTSVisualCue`, () => {
      const abs = join(__dirname, '..', '..', rel)
      const src = readFileSync(abs, 'utf-8')
      expect(src).toMatch(/from\s+['"]@\/components\/TTSVisualCue['"]/)
      expect(src).toMatch(/<TTSVisualCue\s*[^>]*\/?>/)
    })
  }
})
