/**
 * CHT-021 — repeated voice transcripts must overwrite the input.
 *
 * `externalText` was applied via a `useEffect([externalText])`. If the user
 * recorded the same transcript string twice in a row, the prop value did not
 * change so React skipped the effect and the second transcript was silently
 * ignored. The fix uses a separate `externalTextVersion` counter (bumped by
 * the parent on each new transcript) so identical strings still trigger an
 * update.
 */
const mockOpenSettings = jest.fn()

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
    TouchableOpacity: mk('TouchableOpacity'),
    TextInput: mk('TextInput'),
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
    useColorScheme: () => 'light',
    Linking: { openSettings: (...args: unknown[]) => mockOpenSettings(...args) },
  }
})

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: any) =>
      React.createElement('IconSymbol', { testID: `icon-${p.name}`, ...p }),
  }
})

jest.mock('@/components/VoiceMicButton', () => {
  const React = require('react')
  return {
    VoiceMicButton: (p: any) => React.createElement('VoiceMicButton', p),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { TextInput } from 'react-native'
import { ChatInput } from '@/components/ChatInput'

function findTextInput(tree: TestRenderer.ReactTestRenderer): TestRenderer.ReactTestInstance {
  return tree.root.findAll((n) => n.type === TextInput)[0]
}

function textValueOf(tree: TestRenderer.ReactTestRenderer): string {
  return (findTextInput(tree).props as { value: string }).value
}

describe('ChatInput externalText repeated transcripts (CHT-021)', () => {
  it('applies a NEW transcript even when the string is identical to the last', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          externalText="same transcript"
          externalTextVersion={1}
        />,
      )
    })

    expect(textValueOf(tree)).toBe('same transcript')

    // Simulate user editing the input down to empty.
    act(() => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText('')
    })
    expect(textValueOf(tree)).toBe('')

    // Re-record exact same transcript — the version bumps even though
    // the string value didn't change. The input must accept the new
    // value rather than silently ignoring it.
    act(() => {
      tree.update(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          externalText="same transcript"
          externalTextVersion={2}
        />,
      )
    })

    expect(textValueOf(tree)).toBe('same transcript')
  })

  it('still applies a new transcript when the string changes (legacy behaviour preserved)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          externalText="first"
          externalTextVersion={1}
        />,
      )
    })
    expect(textValueOf(tree)).toBe('first')

    act(() => {
      tree.update(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          externalText="second"
          externalTextVersion={2}
        />,
      )
    })
    expect(textValueOf(tree)).toBe('second')
  })
})
