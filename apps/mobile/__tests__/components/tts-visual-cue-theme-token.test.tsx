/**
 * Issue #86 (VIS-026) — TTSVisualCue badge background must come from a
 * theme token rather than the hardcoded Tailwind amber rgba.
 *
 * The cue is a "warning"-styled affordance (it tells the user the
 * paragraph being read references a figure / equation off-screen), so
 * `accent.warning` is the right token in both light & dark schemes.
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
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: () => Promise.resolve(false),
      addEventListener: () => ({ remove: () => {} }),
    },
    Platform: {
      OS: 'ios',
      select: <T,>(opts: { ios?: T; android?: T; default?: T }): T | undefined =>
        opts.ios ?? opts.default,
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { TTSVisualCue } from '@/components/TTSVisualCue'
import { useVisualCueStore } from '@/lib/tts/visual-cue'
import { usePrefsStore } from '@/lib/stores/prefsStore'
import { colorsLight } from '@/lib/theme/colors'

describe('TTSVisualCue badge uses warning theme token (#86)', () => {
  beforeEach(() => {
    useVisualCueStore.getState().clearVisualCue()
  })

  it('uses colorsLight.accent.warning as the badge background', async () => {
    await usePrefsStore.getState().setTtsVisualCueEnabled(true)
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
    const button = tree.root.findByProps({ testID: 'tts-visual-cue' })
    const raw = button.props.style as unknown
    const styles = (Array.isArray(raw) ? raw : [raw]) as Array<{
      backgroundColor?: string
    }>
    const bg = styles
      .map((s) => s?.backgroundColor)
      .find((c) => typeof c === 'string')
    expect(bg).toBe(colorsLight.accent.warning)
    // Defence: assert we are NOT using the legacy Tailwind amber rgba.
    expect(bg).not.toMatch(/rgba\(245,\s*158,\s*11/)
    act(() => tree.unmount())
  })
})
