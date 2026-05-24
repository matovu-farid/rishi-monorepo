/**
 * ConversationRow (mobile) — defect P1-AE.
 *
 * The row truncates long book titles to a single line but previously
 * omitted `ellipsizeMode` (so RN's default 'tail' was used implicitly,
 * which is non-deterministic across platforms) AND set the outer
 * accessibilityLabel to "Conversation about <title>", which prefixed
 * the title with extra prose and made the row's full title unreadable
 * to VoiceOver users when the visible text was truncated.
 *
 * Behaviour pinned here:
 *   1. The title <Text> declares `ellipsizeMode="tail"` explicitly.
 *   2. The outer Pressable's `accessibilityLabel` is the raw book title
 *      so screen readers announce the full (non-truncated) title.
 */

// PRF-005 (#110): ConversationRow now uses useTheme to source its
// press-feedback tint, so the test must provide a theme stub.
jest.mock('@/lib/theme', () => ({
  useTheme: () => ({
    colors: {
      fill: {
        primary: 'rgba(120,120,128,0.20)',
        secondary: 'rgba(120,120,128,0.16)',
        tertiary: 'rgba(118,118,128,0.12)',
        quaternary: 'rgba(116,116,128,0.08)',
      },
    },
  }),
}))

jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: any, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, p.children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    Pressable: mk('Pressable'),
    Image: mk('Image'),
    StyleSheet: { create: (s: Record<string, unknown>) => s, hairlineWidth: 0.5 },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ConversationRow } from '@/components/ConversationRow'
import type { Conversation } from '@/types/conversation'

const longTitle = 'The Extraordinarily Long Title Of A Book About Quantum Mechanics And Philosophy'

const mockConversation: Conversation = {
  id: 'conv-1',
  bookId: 'book-1',
  title: 'My conversation',
  createdAt: 1000,
  updatedAt: 2000,
}

describe('ConversationRow (P1-AE: truncation + a11y)', () => {
  it('declares ellipsizeMode="tail" on the title text', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="row-1"
          conversation={mockConversation}
          bookTitle={longTitle}
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
        />,
      )
    })
    const titleNodes = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        n.type === 'Text' &&
        (n.props as { testID?: string }).testID === 'row-1-title',
    )
    expect(titleNodes.length).toBe(1)
    expect((titleNodes[0].props as { ellipsizeMode?: string }).ellipsizeMode).toBe('tail')
    expect((titleNodes[0].props as { numberOfLines?: number }).numberOfLines).toBe(1)
  })

  it('exposes the full book title via accessibilityLabel on the outer Pressable', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="row-1"
          conversation={mockConversation}
          bookTitle={longTitle}
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
        />,
      )
    })
    const pressables = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        n.type === 'Pressable' &&
        (n.props as { testID?: string }).testID === 'row-1',
    )
    expect(pressables.length).toBe(1)
    expect((pressables[0].props as { accessibilityLabel?: string }).accessibilityLabel).toBe(
      longTitle,
    )
  })
})
