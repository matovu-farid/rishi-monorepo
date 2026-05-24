/**
 * Issue #85 (VIS-025) — Voice-chat pulse animations should use motion
 * duration tokens instead of raw 600 / 800 ms numbers.
 *
 * Strategy: stub react-native-reanimated so that `withTiming` records
 * every call, then mount the buttons in each pulse-active state and
 * verify the duration arg equals the expected token value from
 * `lib/theme/tokens.ts`. Reads the token at runtime so this test
 * survives future token tweaks — it asserts the *binding*, not the
 * literal millisecond.
 */

const withTimingCalls: Array<{ to: unknown; opts?: { duration?: number } }> = []

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: Record<string, unknown>, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, (p as { children?: unknown }).children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    TouchableOpacity: mk('TouchableOpacity'),
    Pressable: mk('Pressable'),
    ActivityIndicator: mk('ActivityIndicator'),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: Record<string, unknown>, r: unknown) =>
    React.createElement('View', { ...p, ref: r }, (p as { children?: unknown }).children),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    useSharedValue: (v: number) => ({ value: v }),
    useAnimatedStyle: (fn: () => unknown) => fn(),
    withRepeat: (v: unknown) => v,
    withTiming: (to: unknown, opts?: { duration?: number }) => {
      withTimingCalls.push({ to, opts })
      return to
    },
    cancelAnimation: jest.fn(),
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: Record<string, unknown>) =>
      React.createElement('IconSymbol', p),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { RealtimeVoiceButton } from '@/components/RealtimeVoiceButton'
import { VoiceMicButton } from '@/components/VoiceMicButton'
import { motion } from '@/lib/theme/tokens'

beforeEach(() => {
  withTimingCalls.length = 0
})

describe('Voice pulse animations use motion tokens (#85)', () => {
  it('RealtimeVoiceButton.active uses motion.duration.pulse for breathing', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <RealtimeVoiceButton status="active" onPress={() => {}} />,
      )
    })
    // The breathing tween moves opacity to 0.6 — match by `to=0.6` so we
    // do not depend on call order.
    const breathing = withTimingCalls.find((c) => c.to === 0.6)
    expect(breathing).toBeDefined()
    expect(breathing!.opts?.duration).toBe(motion.duration.pulse)
    act(() => tree.unmount())
  })

  it('RealtimeVoiceButton.speaking uses motion.duration.pulseFast for scale-pulse', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <RealtimeVoiceButton status="speaking" onPress={() => {}} />,
      )
    })
    // The scale tween targets 1.1 in the speaking sub-state.
    const scalePulse = withTimingCalls.find((c) => c.to === 1.1)
    expect(scalePulse).toBeDefined()
    expect(scalePulse!.opts?.duration).toBe(motion.duration.pulseFast)
    act(() => tree.unmount())
  })

  it('VoiceMicButton recording pulse uses motion.duration.pulse', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <VoiceMicButton
          isRecording
          isTranscribing={false}
          disabled={false}
          onPress={() => {}}
        />,
      )
    })
    const breathing = withTimingCalls.find((c) => c.to === 0.6)
    expect(breathing).toBeDefined()
    expect(breathing!.opts?.duration).toBe(motion.duration.pulse)
    act(() => tree.unmount())
  })
})
