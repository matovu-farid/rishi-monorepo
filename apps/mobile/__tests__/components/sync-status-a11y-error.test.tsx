/**
 * Issue #101 (A11Y-004) — SyncStatusIndicator must announce error
 * transitions to screen-reader users.
 *
 * Two surfaces:
 *   1. Android: the pressable carries `accessibilityLiveRegion="polite"`
 *      whenever the current status is `error`, so the status text re-read
 *      automatically when it appears.
 *   2. iOS & Android (defence in depth): on the transition INTO `error`,
 *      call `AccessibilityInfo.announceForAccessibility` with the
 *      "Sync failed" label so VoiceOver/TalkBack speaks even when the
 *      indicator is not focused.
 */

const announceForAccessibility = jest.fn()

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
    AccessibilityInfo: {
      announceForAccessibility,
    },
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
    withTiming: (v: unknown) => v,
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

let currentStatus: 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline' =
  'not-synced'
jest.mock('@/hooks/useSyncStatus', () => ({
  useSyncStatus: () => ({ status: currentStatus, lastSyncAt: null }),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'

beforeEach(() => {
  announceForAccessibility.mockReset()
  currentStatus = 'not-synced'
})

const findRetryPressable = (tree: TestRenderer.ReactTestRenderer) =>
  tree.root.findAll(
    (n) => (n.props as { testID?: string }).testID === 'sync-status-retry',
  )[0]

describe('SyncStatusIndicator a11y error announcement (#101)', () => {
  it('renders accessibilityLiveRegion="polite" when status is error', () => {
    currentStatus = 'error'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    expect(retry).toBeDefined()
    expect(
      (retry.props as { accessibilityLiveRegion?: string }).accessibilityLiveRegion,
    ).toBe('polite')
    act(() => tree.unmount())
  })

  it('does NOT set live region when status is non-error', () => {
    currentStatus = 'synced'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    expect(retry).toBeDefined()
    const region = (retry.props as { accessibilityLiveRegion?: string })
      .accessibilityLiveRegion
    // Either undefined or "none" is acceptable — anything but "polite"/"assertive".
    expect(region === undefined || region === 'none').toBe(true)
    act(() => tree.unmount())
  })

  it('announces "Sync failed" when status transitions into error', () => {
    currentStatus = 'synced'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    expect(announceForAccessibility).not.toHaveBeenCalled()

    // Transition into error.
    currentStatus = 'error'
    act(() => {
      tree.update(<SyncStatusIndicator />)
    })
    expect(announceForAccessibility).toHaveBeenCalledTimes(1)
    expect(announceForAccessibility.mock.calls[0][0]).toMatch(/sync failed/i)
    act(() => tree.unmount())
  })

  it('does not re-announce while status stays in error', () => {
    currentStatus = 'error'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    expect(announceForAccessibility).toHaveBeenCalledTimes(1)
    // Force a re-render without changing status.
    act(() => {
      tree.update(<SyncStatusIndicator />)
    })
    expect(announceForAccessibility).toHaveBeenCalledTimes(1)
    act(() => tree.unmount())
  })
})
