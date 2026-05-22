/**
 * CHT-018 — ChatMessage text must be user-selectable.
 *
 * Without `selectable` on the assistant-bubble `<Text>`, users can't long-press
 * to copy an answer (or any piece of it) — a glaring parity gap with the
 * electron renderer, which uses a native `<p>` and is selectable by default.
 *
 * We pin `selectable` on the message-text Text element. User bubbles get it
 * too so that long quotations the user pasted in can be re-copied.
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
    ScrollView: mk('ScrollView'),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
    useColorScheme: () => 'light',
  }
})

jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    FadeIn: { duration: () => ({ withInitialValues: () => ({}) }) },
    SlideInRight: { duration: () => ({}) },
    SlideInLeft: { duration: () => ({}) },
  }
})

jest.mock('@/components/SourceReference', () => {
  const React = require('react')
  return {
    SourceReference: (p: any) => React.createElement('SourceReference', p),
    formatSourceLabel: () => '',
    formatSourceHint: () => '',
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { ChatMessage } from '@/components/ChatMessage'
import type { Message } from '@/types/conversation'

function makeMsg(over: Partial<Message> = {}): Message {
  return {
    id: 'm-1',
    conversationId: 'c-1',
    role: 'assistant',
    content: 'The answer is 42.',
    createdAt: 1,
    ...over,
  } as Message
}

function findTextNodes(tree: TestRenderer.ReactTestRenderer) {
  return tree.root.findAll(
    (n) =>
      n.type === 'Text' &&
      (n.props as { testID?: string }).testID?.endsWith('-text') === true,
  )
}

describe('ChatMessage (CHT-018) — selectable text', () => {
  it('renders the assistant message text with selectable=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatMessage message={makeMsg({ role: 'assistant' })} testID="chat-message-assistant-0" />,
      )
    })
    const textNodes = findTextNodes(tree)
    expect(textNodes.length).toBe(1)
    expect((textNodes[0].props as { selectable?: boolean }).selectable).toBe(true)
  })

  it('renders the user message text with selectable=true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatMessage message={makeMsg({ role: 'user' })} testID="chat-message-user-0" />,
      )
    })
    const textNodes = findTextNodes(tree)
    expect(textNodes.length).toBe(1)
    expect((textNodes[0].props as { selectable?: boolean }).selectable).toBe(true)
  })
})
