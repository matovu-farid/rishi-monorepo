/**
 * LockChip (P1-T) — tiny lock-outline / Pro chip rendered next to gated
 * controls when the user is signed out. 12pt icon, no layout shift on the
 * underlying control (positioned absolutely by the caller).
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
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Platform: { OS: 'ios' },
    useColorScheme: () => 'light',
  }
})

jest.mock('@expo/vector-icons/Ionicons', () => {
  const React = require('react')
  const Ionicons = (p: any) =>
    React.createElement('Ionicons', { testID: `ion-${p.name}`, ...p })
  return { __esModule: true, default: Ionicons, glyphMap: {} }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { LockChip } from '@/components/auth/LockChip'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

describe('LockChip (P1-T)', () => {
  it('renders a host node with testID="lock-chip"', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LockChip />)
    })
    expect(findByTestID(tree, 'lock-chip')).not.toBeNull()
  })

  it('renders an Ionicons lock-closed icon at 12pt by default', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LockChip />)
    })
    const ion = findByTestID(tree, 'ion-lock-closed')
    expect(ion).not.toBeNull()
    expect((ion!.props as { size?: number }).size).toBe(12)
  })

  it('forwards a custom testID to the host', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LockChip testID="tts-lock-chip" />)
    })
    expect(findByTestID(tree, 'tts-lock-chip')).not.toBeNull()
  })

  it('has accessibilityLabel="Sign in required"', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<LockChip />)
    })
    const chip = findByTestID(tree, 'lock-chip')
    expect(
      (chip!.props as { accessibilityLabel?: string }).accessibilityLabel,
    ).toBe('Sign in required')
  })
})
