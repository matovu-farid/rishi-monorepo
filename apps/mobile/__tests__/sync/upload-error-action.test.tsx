/**
 * STA-019 — UploadErrorSnackbar should expose an actionable next-step.
 *
 * Background: the upload-cap snackbar previously rendered the formatted
 * message with no CTA. All three cap errors (per-file 800 MB, per-user
 * 500 books, per-user 10 GB) collapsed into a passive notice and the user
 * had no path forward.
 *
 * Contract this file pins:
 *   1. `formatUploadLimitAction` returns a kind + label per error code.
 *   2. `useUploadErrorStore.show(...)` captures that `action` on the
 *      current notice so subscribers can render the CTA.
 *   3. `UploadErrorSnackbar` renders the action label as an UndoSnackbar
 *      button when the notice has one, and invoking the button
 *      both navigates to the storage settings target AND dismisses the
 *      notice.
 *
 * Tests are TDD-first — they exercise behaviour the production code does
 * not yet implement.
 */

jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((p: any, r: unknown) =>
      React.createElement('View', { ...p, ref: r }),
    ),
    Text: React.forwardRef((p: any, r: unknown) =>
      React.createElement('Text', { ...p, ref: r }),
    ),
    Pressable: React.forwardRef((p: any, r: unknown) =>
      React.createElement('Pressable', { ...p, ref: r }),
    ),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('View', { ...p, ref: r }),
  )
  return {
    __esModule: true,
    default: { View },
    FadeInDown: { duration: () => null },
    FadeOutDown: { duration: () => null },
  }
})

const routerPushMock = jest.fn()
jest.mock('expo-router', () => ({
  useRouter: () => ({ push: routerPushMock, replace: jest.fn() }),
  router: { push: routerPushMock, replace: jest.fn() },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { UploadErrorSnackbar } from '@/components/UploadErrorSnackbar'
import {
  useUploadErrorStore,
  formatUploadLimitAction,
} from '@/lib/sync/upload-error-store'

describe('formatUploadLimitAction', () => {
  it('returns a manage-books action for BOOK_LIMIT_REACHED', () => {
    const action = formatUploadLimitAction({
      code: 'BOOK_LIMIT_REACHED',
      limit: 500,
    })
    expect(action).not.toBeNull()
    expect(action?.kind).toBe('manage-books')
    expect(action?.label).toMatch(/manage|library|books/i)
  })

  it('returns a manage-storage action for STORAGE_LIMIT_REACHED', () => {
    const action = formatUploadLimitAction({
      code: 'STORAGE_LIMIT_REACHED',
      limit: 10 * 1024 * 1024 * 1024,
    })
    expect(action).not.toBeNull()
    expect(action?.kind).toBe('manage-storage')
    expect(action?.label).toMatch(/storage|space|manage/i)
  })

  it('returns a manage-storage action for FILE_TOO_LARGE', () => {
    // A 800 MB file can't be shrunk in-app, but the user can still see how
    // close they are to the cap, so we point them at Storage.
    const action = formatUploadLimitAction({
      code: 'FILE_TOO_LARGE',
      limit: 800 * 1024 * 1024,
    })
    expect(action).not.toBeNull()
    expect(action?.kind).toBe('manage-storage')
  })
})

describe('useUploadErrorStore.show captures action metadata', () => {
  beforeEach(() => {
    useUploadErrorStore.getState().dismiss()
  })

  it('exposes the action on the current notice', () => {
    useUploadErrorStore.getState().show({
      code: 'BOOK_LIMIT_REACHED',
      limit: 500,
    })
    const current = useUploadErrorStore.getState().current
    expect(current?.action).toBeDefined()
    expect(current?.action?.kind).toBe('manage-books')
  })
})

describe('UploadErrorSnackbar action button', () => {
  beforeEach(() => {
    routerPushMock.mockReset()
    act(() => {
      useUploadErrorStore.getState().dismiss()
    })
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('renders the action label as a snackbar button', () => {
    let root!: TestRenderer.ReactTestRenderer
    act(() => {
      root = TestRenderer.create(<UploadErrorSnackbar />)
    })
    act(() => {
      useUploadErrorStore.getState().show({
        code: 'BOOK_LIMIT_REACHED',
        limit: 500,
      })
    })
    const tree = JSON.stringify(root.toJSON())
    expect(tree).toMatch(/Manage/i)
  })

  it('invoking the action navigates to settings and dismisses the notice', () => {
    let root!: TestRenderer.ReactTestRenderer
    act(() => {
      root = TestRenderer.create(<UploadErrorSnackbar />)
    })
    act(() => {
      useUploadErrorStore.getState().show({
        code: 'STORAGE_LIMIT_REACHED',
        limit: 10 * 1024 * 1024 * 1024,
      })
    })
    // Find the action Pressable by testID.
    const actionNode = root.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'undo-snackbar-action',
    )[0]
    expect(actionNode).toBeDefined()
    act(() => {
      ;(actionNode.props as { onPress?: () => void }).onPress?.()
    })
    expect(routerPushMock).toHaveBeenCalledWith('/(tabs)/settings')
    expect(useUploadErrorStore.getState().current).toBeNull()
  })
})
