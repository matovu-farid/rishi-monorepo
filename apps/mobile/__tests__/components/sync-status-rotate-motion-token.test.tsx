/**
 * Issue #90 (VIS-030) — SyncStatusIndicator rotation must come from a
 * motion token, not a raw 1000 ms literal.
 *
 * The rotation is a *period* (full revolution time) for the indeterminate
 * spinner — semantically distinct from fast/normal/slow UI tweens, hence
 * the `motion.duration.rotate` token.
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
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Alert: { alert: jest.fn() },
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

jest.mock('@/lib/sync/engine', () => ({ sync: jest.fn() }))
jest.mock('@/lib/sync/file-sync', () => ({ downloadBookFile: jest.fn() }))
jest.mock('@/hooks/useSyncStatus', () => ({
  useSyncStatus: () => ({ status: 'syncing', lastSyncAt: null }),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'
import { motion } from '@/lib/theme/tokens'

beforeEach(() => {
  withTimingCalls.length = 0
})

describe('SyncStatusIndicator rotation uses motion token (#90)', () => {
  it('full revolution tween targets 360deg with motion.duration.rotate', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const rev = withTimingCalls.find((c) => c.to === 360)
    expect(rev).toBeDefined()
    expect(rev!.opts?.duration).toBe(motion.duration.rotate)
    act(() => tree.unmount())
  })
})
