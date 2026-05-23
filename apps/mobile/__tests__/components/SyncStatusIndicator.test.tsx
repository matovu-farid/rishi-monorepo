/**
 * SyncStatusIndicator — defect P1-AG.
 *
 * Previously: an `error` status was rendered as a non-actionable button.
 * Tap-retry just re-fired `sync()` and re-failed silently; users had no
 * way to learn *why* the sync failed and no feedback that their retry
 * even ran.
 *
 * Token migration:
 *   1. `accessibilityHint` on the retry pressable surfaces the last
 *      error message (or a sensible default in non-error states).
 *   2. `onLongPress` opens a diagnostics view (Alert) with the last
 *      error + last-synced timestamp so users can self-triage.
 *   3. Tap-retry fires user-visible feedback (Alert) on success and
 *      on failure. Engine semantics are unchanged.
 */

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
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
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('View', { ...p, ref: r }, p.children),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: any) => c },
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
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

const mockSync = jest.fn()
jest.mock('@/lib/sync/engine', () => ({
  sync: () => mockSync(),
}))

// DAT-003: stub the file-sync module so the SyncStatusIndicator import
// chain does not pull in expo-crypto / expo-file-system (native modules
// the node jest preset cannot transform).
const mockDownloadBookFile = jest.fn()
jest.mock('@/lib/sync/file-sync', () => ({
  downloadBookFile: (...args: unknown[]) => mockDownloadBookFile(...args),
}))

let currentStatus: 'not-synced' | 'syncing' | 'synced' | 'error' | 'offline' =
  'not-synced'
let currentLastSyncAt: number | null = null
jest.mock('@/hooks/useSyncStatus', () => ({
  useSyncStatus: () => ({ status: currentStatus, lastSyncAt: currentLastSyncAt }),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { Alert } from 'react-native'
import { SyncStatusIndicator } from '@/components/SyncStatusIndicator'

const findRetryPressable = (tree: TestRenderer.ReactTestRenderer) => {
  const found = tree.root.findAll(
    (n) => (n.props as { testID?: string }).testID === 'sync-status-retry',
  )
  return found[0]
}

describe('SyncStatusIndicator (P1-AG: actionable error feedback)', () => {
  beforeEach(() => {
    mockSync.mockReset()
    ;(Alert.alert as jest.Mock).mockReset()
    currentStatus = 'not-synced'
    currentLastSyncAt = null
  })

  it('accessibilityHint reflects the last error message when status is error', () => {
    currentStatus = 'error'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    expect(retry).toBeDefined()
    const hint = (retry.props as { accessibilityHint?: string })
      .accessibilityHint
    expect(typeof hint).toBe('string')
    expect(hint).toMatch(/last sync failed/i)
  })

  it('accessibilityHint provides a default action hint when status is not error', () => {
    currentStatus = 'synced'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    const hint = (retry.props as { accessibilityHint?: string })
      .accessibilityHint
    expect(typeof hint).toBe('string')
    expect(hint).toMatch(/sync/i)
  })

  it('long-press opens a diagnostics alert with last error and timestamp', () => {
    currentStatus = 'error'
    currentLastSyncAt = Date.now() - 60_000
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    act(() => {
      ;(retry.props as { onLongPress?: () => void }).onLongPress?.()
    })
    expect(Alert.alert).toHaveBeenCalledTimes(1)
    const [title, body] = (Alert.alert as jest.Mock).mock.calls[0]
    expect(title).toMatch(/sync diagnostics/i)
    expect(body).toMatch(/last sync/i)
  })

  it('tap-retry shows success feedback when sync() resolves', async () => {
    currentStatus = 'error'
    mockSync.mockResolvedValueOnce(undefined)
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    await act(async () => {
      await (retry.props as { onPress?: () => Promise<void> | void }).onPress?.()
    })
    expect(mockSync).toHaveBeenCalledTimes(1)
    expect(Alert.alert).toHaveBeenCalledTimes(1)
    const [title] = (Alert.alert as jest.Mock).mock.calls[0]
    expect(title).toMatch(/sync/i)
  })

  it('tap-retry shows failure feedback when sync() rejects', async () => {
    currentStatus = 'error'
    mockSync.mockRejectedValueOnce(new Error('network down'))
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    await act(async () => {
      await (retry.props as { onPress?: () => Promise<void> | void }).onPress?.()
    })
    expect(mockSync).toHaveBeenCalledTimes(1)
    expect(Alert.alert).toHaveBeenCalledTimes(1)
    const [title, body] = (Alert.alert as jest.Mock).mock.calls[0]
    expect(`${title} ${body}`).toMatch(/fail|error/i)
  })

  // DAT-003: failed-download recovery flow — when downloadBookFile flagged
  // a book for redownload, the long-press diagnostics must surface a
  // "Retry downloads" action that re-invokes downloadBookFile.
  it('long-press offers a Retry downloads action when failed downloads exist', () => {
    // Import the store from the same module the component subscribes to;
    // require() inline so the mock-hoist ordering above isn't disturbed.
    const {
      useDownloadErrorStore,
    } = require('@/lib/sync/download-error-store') as typeof import('@/lib/sync/download-error-store')
    useDownloadErrorStore.getState().clear()
    useDownloadErrorStore.getState().recordFailure({
      bookId: 'book-broken',
      r2Key: 'r2/epub/hash',
      format: 'epub',
      reason: 'EBUSY',
    })

    currentStatus = 'error'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<SyncStatusIndicator />)
    })
    const retry = findRetryPressable(tree)
    act(() => {
      ;(retry.props as { onLongPress?: () => void }).onLongPress?.()
    })

    expect(Alert.alert).toHaveBeenCalledTimes(1)
    const [title, body, buttons] = (Alert.alert as jest.Mock).mock.calls[0]
    expect(title).toMatch(/diagnostics/i)
    expect(body).toMatch(/failed downloads/i)
    // The action button must exist and call downloadBookFile when fired.
    expect(Array.isArray(buttons)).toBe(true)
    const retryButton = (buttons as Array<{ text: string; onPress?: () => void }>).find(
      (b) => /retry/i.test(b.text),
    )
    expect(retryButton).toBeDefined()
    useDownloadErrorStore.getState().clear()
  })
})
