/**
 * PRF-005 (#110) — ConversationRow press feedback must not rely on
 * NativeWind's `active:bg-gray-100 dark:active:bg-gray-800` className
 * (NativeWind has to re-parse the className on every press / theme
 * change). Switch to RN's `Pressable` `style={({ pressed }) => [...]}`
 * callback so the pressed background is sourced from a StyleSheet
 * entry — no className parsing on the hot path.
 *
 * Behaviour pinned here:
 *   1. Pressable's `style` prop is a function (the press-feedback
 *      callback), not just a string of NativeWind classes.
 *   2. Invoking the style function with `{ pressed: false }` returns
 *      a style WITHOUT a pressed-state backgroundColor.
 *   3. Invoking the style function with `{ pressed: true }` returns
 *      a style WITH a backgroundColor (proving the pressed state
 *      really flips a stylesheet value).
 *   4. The Pressable does NOT carry the legacy `active:` className
 *      tokens any more.
 */

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
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      hairlineWidth: 0.5,
    },
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

const mockConversation: Conversation = {
  id: 'c1',
  bookId: 'b1',
  title: 'My conversation',
  createdAt: 1000,
  updatedAt: 2000,
}

function flattenStyle(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) {
    return Object.assign({}, ...style.map((s) => flattenStyle(s)))
  }
  return style as Record<string, unknown>
}

describe('ConversationRow press feedback (PRF-005 / #110)', () => {
  function renderRow(): TestRenderer.ReactTestRenderer {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="conv-row"
          conversation={mockConversation}
          bookTitle="Book"
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
        />,
      )
    })
    return tree
  }

  function getPressable(
    tree: TestRenderer.ReactTestRenderer,
  ): TestRenderer.ReactTestInstance {
    const pressables = tree.root.findAll(
      (n) =>
        typeof n.type === 'string' &&
        (n.type as string) === 'Pressable' &&
        (n.props as { testID?: string }).testID === 'conv-row',
    )
    expect(pressables.length).toBe(1)
    return pressables[0]!
  }

  it('uses a style callback, not a static style or className-only press state', () => {
    const tree = renderRow()
    const press = getPressable(tree)
    const style = (press.props as { style?: unknown }).style
    expect(typeof style).toBe('function')
  })

  it('returns no pressed-state backgroundColor when not pressed', () => {
    const tree = renderRow()
    const press = getPressable(tree)
    const styleFn = (press.props as { style: ({ pressed }: { pressed: boolean }) => unknown })
      .style
    const flat = flattenStyle(styleFn({ pressed: false }))
    // When idle the backgroundColor is undefined (or `'transparent'` —
    // any non-tinted value). Either way it is NOT the pressed tint.
    expect(flat.backgroundColor === undefined || flat.backgroundColor === 'transparent').toBe(
      true,
    )
  })

  it('returns a backgroundColor when pressed (StyleSheet-backed)', () => {
    const tree = renderRow()
    const press = getPressable(tree)
    const styleFn = (press.props as { style: ({ pressed }: { pressed: boolean }) => unknown })
      .style
    const flat = flattenStyle(styleFn({ pressed: true }))
    expect(typeof flat.backgroundColor).toBe('string')
    expect(flat.backgroundColor).not.toBe('transparent')
    expect((flat.backgroundColor as string).length).toBeGreaterThan(0)
  })

  it('drops the legacy `active:bg-gray-...` className tokens', () => {
    const tree = renderRow()
    const press = getPressable(tree)
    const className = (press.props as { className?: string }).className ?? ''
    expect(className).not.toMatch(/active:bg-gray-/)
  })
})
