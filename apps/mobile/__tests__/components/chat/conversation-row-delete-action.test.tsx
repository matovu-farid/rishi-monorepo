/**
 * ConversationRow — issue #60.
 *
 * Before this change, the only way to delete a conversation was the
 * `onLongPress` gesture on the row's outer Pressable. Users had no
 * visible affordance for that gesture, so the destructive action was
 * effectively invisible.
 *
 * The fix adds a discoverable swipe-to-delete affordance via
 * `react-native-gesture-handler/ReanimatedSwipeable`. When the consumer
 * passes a new `onSwipeDelete` prop, the row is wrapped in a
 * ReanimatedSwipeable whose `renderRightActions` returns a Pressable
 * styled as a destructive button. The existing `onLongPress` continues
 * to work as a power-user shortcut.
 *
 * We pin the following observable behaviour:
 *   1. When `onSwipeDelete` is provided, the rendered tree contains a
 *      Pressable with testID `${testID}-delete-action`.
 *   2. That Pressable carries the destructive a11y triad
 *      (role / label / hint).
 *   3. Pressing the action fires `onSwipeDelete` exactly once.
 *   4. When `onSwipeDelete` is NOT provided, no delete-action node is
 *      rendered (backwards compatibility — existing call sites that only
 *      pass `onLongPress` keep their original shape).
 *
 * Why mock ReanimatedSwipeable: jest runs in `testEnvironment: 'node'`
 * without the rngh native runtime. Our mock immediately invokes
 * `renderRightActions` so the destructive node is present in the
 * snapshot — that's the surface the test exercises.
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

// Mock ReanimatedSwipeable: render the right-actions output inline so the
// test tree contains the destructive node without any gesture activation.
// The real component animates the actions in based on drag distance; for
// the purposes of asserting affordance + a11y + handler wiring we only
// need the rendered subtree.
jest.mock('react-native-gesture-handler/ReanimatedSwipeable', () => {
  const React = require('react')
  return {
    __esModule: true,
    default: ({
      renderRightActions,
      children,
    }: {
      renderRightActions?: (
        progress: unknown,
        translation: unknown,
        methods: unknown,
      ) => unknown
      children?: React.ReactNode
    }) =>
      React.createElement(
        'ReanimatedSwipeable',
        null,
        renderRightActions
          ? renderRightActions(
              { value: 0 },
              { value: 0 },
              { close: () => {}, openLeft: () => {}, openRight: () => {}, reset: () => {} },
            )
          : null,
        children,
      ),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ConversationRow } from '@/components/ConversationRow'
import type { Conversation } from '@/types/conversation'

const mockConversation: Conversation = {
  id: 'conv-1',
  bookId: 'book-1',
  title: 'My conversation',
  createdAt: 1000,
  updatedAt: 2000,
}

describe('ConversationRow (#60: visible delete affordance via swipe)', () => {
  it('renders a destructive delete-action Pressable when onSwipeDelete is provided', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="conversation-row-conv-1"
          conversation={mockConversation}
          bookTitle="War and Peace"
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
          onSwipeDelete={() => {}}
        />,
      )
    })

    const deleteActions = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID ===
        'conversation-row-conv-1-delete-action',
    )
    expect(deleteActions.length).toBe(1)
  })

  it('exposes the destructive a11y triad on the delete-action node', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="conversation-row-conv-1"
          conversation={mockConversation}
          bookTitle="War and Peace"
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
          onSwipeDelete={() => {}}
        />,
      )
    })

    const deleteAction = tree.root.find(
      (n) =>
        (n.props as { testID?: string }).testID ===
        'conversation-row-conv-1-delete-action',
    )
    const props = deleteAction.props as {
      accessibilityRole?: string
      accessibilityLabel?: string
      accessibilityHint?: string
    }
    expect(props.accessibilityRole).toBe('button')
    expect(props.accessibilityLabel).toBe('Delete conversation')
    expect(props.accessibilityHint).toBe('Removes the conversation permanently')
  })

  it('fires onSwipeDelete exactly once when the delete-action node is pressed', () => {
    const onSwipeDelete = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="conversation-row-conv-1"
          conversation={mockConversation}
          bookTitle="War and Peace"
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
          onSwipeDelete={onSwipeDelete}
        />,
      )
    })

    const deleteAction = tree.root.find(
      (n) =>
        (n.props as { testID?: string }).testID ===
        'conversation-row-conv-1-delete-action',
    )
    act(() => {
      ;(deleteAction.props as { onPress?: () => void }).onPress?.()
    })
    expect(onSwipeDelete).toHaveBeenCalledTimes(1)
  })

  it('omits the delete-action node when onSwipeDelete is not provided', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ConversationRow
          testID="conversation-row-conv-1"
          conversation={mockConversation}
          bookTitle="War and Peace"
          bookCoverPath={null}
          onPress={() => {}}
          onLongPress={() => {}}
        />,
      )
    })

    const deleteActions = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID ===
        'conversation-row-conv-1-delete-action',
    )
    expect(deleteActions.length).toBe(0)
  })
})
