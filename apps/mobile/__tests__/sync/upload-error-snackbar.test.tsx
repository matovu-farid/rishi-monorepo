/**
 * Verifies the UploadErrorSnackbar renders the formatted message from the
 * store. Mirrors the existing `highlights/undo-snackbar.test.tsx` mock setup
 * for react-native primitives so we stay in the `testEnvironment: 'node'`
 * sandbox.
 */
jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((p: any, r: unknown) => React.createElement('View', { ...p, ref: r })),
    Text: React.forwardRef((p: any, r: unknown) => React.createElement('Text', { ...p, ref: r })),
    Pressable: React.forwardRef((p: any, r: unknown) =>
      React.createElement('Pressable', { ...p, ref: r }),
    ),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
  }
})

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  // Animated.View used by UndoSnackbar — stub as a plain View pass-through.
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

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { UploadErrorSnackbar } from '@/components/UploadErrorSnackbar'
import { useUploadErrorStore } from '@/lib/sync/upload-error-store'

describe('UploadErrorSnackbar', () => {
  beforeEach(() => {
    act(() => {
      useUploadErrorStore.getState().dismiss()
    })
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('renders nothing when there is no current notice', () => {
    let root!: TestRenderer.ReactTestRenderer
    act(() => {
      root = TestRenderer.create(<UploadErrorSnackbar />)
    })
    expect(root.toJSON()).toBeNull()
  })

  it('renders the formatted message when the store has a notice', () => {
    let root!: TestRenderer.ReactTestRenderer
    act(() => {
      root = TestRenderer.create(<UploadErrorSnackbar />)
    })
    act(() => {
      useUploadErrorStore.getState().show({
        code: 'FILE_TOO_LARGE',
        limit: 800 * 1024 * 1024,
      })
    })
    // The snackbar's <Text> child should contain "800 MB".
    const tree = JSON.stringify(root.toJSON())
    expect(tree).toMatch(/800 MB/)
  })

  it('auto-dismisses after the timer fires', () => {
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
    expect(useUploadErrorStore.getState().current).not.toBeNull()
    act(() => {
      jest.advanceTimersByTime(6_001)
    })
    expect(useUploadErrorStore.getState().current).toBeNull()
  })
})
