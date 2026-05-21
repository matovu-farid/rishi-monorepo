/**
 * G20 — Reader screens must register a page-capture ref on mount and
 * clear it on unmount so the voice-chat vision tool can capture the
 * currently-visible page.
 *
 * We don't render the full reader screens (they pull in too many native
 * deps); instead we exercise the small `usePageCaptureRef` hook each
 * reader screen consumes and assert the registration / unregistration
 * contract directly.
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

jest.mock('react-native-view-shot', () => ({
  captureRef: jest.fn(),
}), { virtual: true })

// Avoid pulling in the real react-native (ESM). The hook just calls
// `setActivePageCaptureRef`; we don't need any RN host components.
jest.mock('react-native', () => {
  const React = require('react')
  return {
    View: React.forwardRef((props: Record<string, unknown>, ref: unknown) =>
      React.createElement('View', { ...props, ref }),
    ),
  }
})

import React, { useRef } from 'react'
import TestRenderer, { act } from 'react-test-renderer'
import { View } from 'react-native'
import {
  getActivePageCaptureRef,
  setActivePageCaptureRef,
} from '@/lib/voice-chat/page-capture'
import { usePageCaptureRef } from '@/hooks/usePageCaptureRef'

function Probe() {
  const ref = useRef<unknown>(null)
  usePageCaptureRef(ref)
  return <View ref={ref as never} testID="probe" />
}

describe('usePageCaptureRef', () => {
  beforeEach(() => {
    setActivePageCaptureRef(null)
  })

  it('registers the supplied ref on mount', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Probe />)
    })
    const registered = getActivePageCaptureRef()
    expect(registered).not.toBeNull()
    act(() => {
      tree.unmount()
    })
  })

  it('clears the registration on unmount', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<Probe />)
    })
    expect(getActivePageCaptureRef()).not.toBeNull()
    act(() => {
      tree.unmount()
    })
    expect(getActivePageCaptureRef()).toBeNull()
  })

  it('two probes mounting in sequence each register and clear', () => {
    let treeA!: TestRenderer.ReactTestRenderer
    act(() => {
      treeA = TestRenderer.create(<Probe />)
    })
    const refA = getActivePageCaptureRef()
    expect(refA).not.toBeNull()
    act(() => {
      treeA.unmount()
    })
    expect(getActivePageCaptureRef()).toBeNull()

    let treeB!: TestRenderer.ReactTestRenderer
    act(() => {
      treeB = TestRenderer.create(<Probe />)
    })
    const refB = getActivePageCaptureRef()
    expect(refB).not.toBeNull()
    act(() => {
      treeB.unmount()
    })
    expect(getActivePageCaptureRef()).toBeNull()
  })

  it('replaces an existing registration when a new probe mounts before the old one unmounts', () => {
    let treeA!: TestRenderer.ReactTestRenderer
    let treeB!: TestRenderer.ReactTestRenderer
    act(() => {
      treeA = TestRenderer.create(<Probe />)
    })
    const refA = getActivePageCaptureRef()
    act(() => {
      treeB = TestRenderer.create(<Probe />)
    })
    const refB = getActivePageCaptureRef()
    expect(refB).not.toBe(refA)
    // When B unmounts it must clear (it owns the slot last).
    act(() => {
      treeB.unmount()
    })
    expect(getActivePageCaptureRef()).toBeNull()
    act(() => {
      treeA.unmount()
    })
  })
})
