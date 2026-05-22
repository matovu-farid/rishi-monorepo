/**
 * P1-AK — ChatInput (mobile).
 *
 * The chat input owns the in-progress draft text. Historically it cleared
 * the input synchronously BEFORE calling `onSend`, so when `onSend` was
 * intercepted by the premium-feature gate (signed-out user), the typed
 * message was lost behind the sheet. The previous workaround was a
 * `clearOnSend` prop driven by `isAuthenticated`, leaking gating state
 * into the input's API.
 *
 * The refactor: ChatInput captures the text in a closure passed to
 * `onSend`, then clears the local state AFTER `onSend` returns. The
 * authStore is responsible for replaying that closure on sign-in (P0-U),
 * so the captured `text` survives the round-trip even though ChatInput
 * has already cleared its own state.
 *
 * Net: ChatInput no longer accepts `clearOnSend`. Its contract is
 * "always clear after onSend returns".
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
import { Pressable, TextInput, TouchableOpacity } from 'react-native'
import { ChatInput } from '@/components/ChatInput'

function findTextInput(tree: TestRenderer.ReactTestRenderer): TestRenderer.ReactTestInstance {
  return tree.root.findAll((n) => n.type === TextInput)[0]
}

function findSendButton(tree: TestRenderer.ReactTestRenderer): TestRenderer.ReactTestInstance {
  return tree.root.findAll(
    (n) =>
      n.type === TouchableOpacity &&
      (n.props as { testID?: string }).testID === 'chat-send-btn',
  )[0]
}

function textValueOf(tree: TestRenderer.ReactTestRenderer): string {
  return (findTextInput(tree).props as { value: string }).value
}

describe('ChatInput (mobile) — P1-AK clearAfterAccepted', () => {
  it('forwards the typed text to onSend when the send button is pressed', () => {
    const onSend = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput onSend={onSend} isLoading={false} disabled={false} />,
      )
    })

    act(() => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText(
        'hello',
      )
    })
    act(() => {
      ;(findSendButton(tree).props as { onPress: () => void }).onPress()
    })

    expect(onSend).toHaveBeenCalledTimes(1)
    expect(onSend).toHaveBeenCalledWith('hello')
  })

  it('passes the captured text to onSend (closure) and only THEN clears the input', () => {
    // The captured text must reach `onSend` even though the input clears
    // afterwards. This is the contract that makes P0-U replay-after-sign-in
    // work — the closure carries the message through the gate round-trip.
    let captured: string | null = null
    const onSend = jest.fn((t: string) => {
      captured = t
    })

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput onSend={onSend} isLoading={false} disabled={false} />,
      )
    })

    act(() => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText(
        'persisted-draft',
      )
    })
    act(() => {
      ;(findSendButton(tree).props as { onPress: () => void }).onPress()
    })

    expect(captured).toBe('persisted-draft')
    // After onSend returns, the input MUST be cleared.
    expect(textValueOf(tree)).toBe('')
  })

  it('preserves the draft when a synchronous onSend throws (clears only on success)', () => {
    // Distinguishing test for the refactor:
    //   - OLD behaviour: clearOnSend defaulted to true and cleared BEFORE
    //     invoking onSend. A throwing onSend therefore lost the user's text.
    //   - NEW behaviour: ChatInput clears only AFTER onSend returns
    //     successfully. A throwing onSend leaves the text in place so the
    //     user can retry without retyping.
    const onSend = jest.fn(() => {
      throw new Error('send failed')
    })

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput onSend={onSend} isLoading={false} disabled={false} />,
      )
    })
    act(() => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText(
        'sync-failure',
      )
    })
    act(() => {
      try {
        ;(findSendButton(tree).props as { onPress: () => void }).onPress()
      } catch {
        // swallow — ChatInput is allowed to rethrow
      }
    })

    expect(onSend).toHaveBeenCalledWith('sync-failure')
    expect(textValueOf(tree)).toBe('sync-failure')
  })

  it('clears AFTER an async onSend resolves (Promise-aware)', async () => {
    let resolveSend: () => void = () => undefined
    const sendPromise = new Promise<void>((res) => {
      resolveSend = res
    })
    const onSend = jest.fn(() => sendPromise)

    let tree!: TestRenderer.ReactTestRenderer
    await act(async () => {
      tree = TestRenderer.create(
        <ChatInput onSend={onSend} isLoading={false} disabled={false} />,
      )
    })
    await act(async () => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText(
        'async-draft',
      )
    })
    await act(async () => {
      ;(findSendButton(tree).props as { onPress: () => void | Promise<void> }).onPress()
    })

    // onSend has been called with the captured text.
    expect(onSend).toHaveBeenCalledWith('async-draft')

    // After the send promise resolves, the input is cleared.
    await act(async () => {
      resolveSend()
      await sendPromise
    })
    expect(textValueOf(tree)).toBe('')
  })

  it('does NOT call onSend when the text is empty or whitespace', () => {
    const onSend = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput onSend={onSend} isLoading={false} disabled={false} />,
      )
    })
    act(() => {
      ;(findTextInput(tree).props as { onChangeText: (t: string) => void }).onChangeText(
        '   ',
      )
    })
    act(() => {
      ;(findSendButton(tree).props as { onPress: (() => void) | undefined }).onPress?.()
    })
    expect(onSend).not.toHaveBeenCalled()
  })
})

/**
 * P1-Z — Voice mic permission denial is silent on iOS.
 *
 * iOS only prompts for the microphone permission once. After the user
 * taps "Don't allow", subsequent calls to
 * `requestRecordingPermissionsAsync` resolve immediately with
 * `{ granted: false }` — no system sheet appears. Previously the UI
 * just showed a red error string and the user had no way out; the only
 * remediation is the iOS Settings app.
 *
 * Fix: when `permissionDenied` is true, ChatInput renders a tappable
 * "Open Settings" Pressable that calls `Linking.openSettings()`.
 */
describe('ChatInput (mobile) — P1-Z mic permission denied → Open Settings', () => {
  beforeEach(() => {
    mockOpenSettings.mockReset()
  })

  it('renders an "Open Settings" pressable when permissionDenied is true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          onMicPress={jest.fn()}
          permissionDenied
        />,
      )
    })

    const settingsButton = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { testID?: string }).testID === 'mic-open-settings',
    )
    expect(settingsButton.length).toBe(1)
  })

  it('does NOT render the "Open Settings" pressable when permissionDenied is false', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          onMicPress={jest.fn()}
          permissionDenied={false}
        />,
      )
    })

    const settingsButton = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { testID?: string }).testID === 'mic-open-settings',
    )
    expect(settingsButton.length).toBe(0)
  })

  it('invokes Linking.openSettings when the "Open Settings" pressable is tapped', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={false}
          disabled={false}
          onMicPress={jest.fn()}
          permissionDenied
        />,
      )
    })

    const settingsButton = tree.root.findAll(
      (n) =>
        n.type === Pressable &&
        (n.props as { testID?: string }).testID === 'mic-open-settings',
    )[0]
    expect(settingsButton).toBeTruthy()

    act(() => {
      ;(settingsButton.props as { onPress: () => void }).onPress()
    })
    expect(mockOpenSettings).toHaveBeenCalledTimes(1)
  })
})

/**
 * P1-AI — ChatInput "stop" button does nothing.
 *
 * While `isLoading` is true, the send button morphs into a stop-fill
 * icon — but the previous implementation set `onPress={undefined}`, so
 * tapping it was a no-op. The user could not cancel a slow / hung
 * generation; their only option was to back out of the screen.
 *
 * Fix: accept an optional `onAbort` prop. When `isLoading` and
 * `onAbort` is provided, pressing the stop icon invokes the callback.
 * Parents wire `onAbort` to an `AbortController.abort()` (matches the
 * electron `useChat` hook contract).
 *
 * Backwards-compat: when `onAbort` is absent the stop icon stays a
 * no-op (no regression for callers that haven't migrated yet).
 */
describe('ChatInput (mobile) — P1-AI stop button → onAbort', () => {
  function findSendButtonForAbort(
    tree: TestRenderer.ReactTestRenderer,
  ): TestRenderer.ReactTestInstance {
    return tree.root.findAll(
      (n) =>
        n.type === TouchableOpacity &&
        (n.props as { testID?: string }).testID === 'chat-send-btn',
    )[0]
  }

  it('calls onAbort when the stop icon is pressed while isLoading', () => {
    const onAbort = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={true}
          disabled={false}
          onAbort={onAbort}
        />,
      )
    })

    const btn = findSendButtonForAbort(tree)
    expect(btn).toBeTruthy()
    act(() => {
      ;(btn.props as { onPress?: () => void }).onPress?.()
    })
    expect(onAbort).toHaveBeenCalledTimes(1)
  })

  it('shows the stop icon when isLoading is true', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={jest.fn()}
          isLoading={true}
          disabled={false}
          onAbort={jest.fn()}
        />,
      )
    })

    const stopIcons = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === 'icon-stop.fill',
    )
    expect(stopIcons.length).toBeGreaterThanOrEqual(1)
  })

  it('does NOT invoke onSend when the stop icon is pressed', () => {
    const onSend = jest.fn()
    const onAbort = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput
          onSend={onSend}
          isLoading={true}
          disabled={false}
          onAbort={onAbort}
        />,
      )
    })
    act(() => {
      ;(findSendButtonForAbort(tree).props as { onPress?: () => void }).onPress?.()
    })
    expect(onSend).not.toHaveBeenCalled()
    expect(onAbort).toHaveBeenCalledTimes(1)
  })

  it('stop button stays a safe no-op when onAbort is not provided', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ChatInput onSend={jest.fn()} isLoading={true} disabled={false} />,
      )
    })
    // Tapping must not throw, even though no abort handler is wired up.
    expect(() => {
      act(() => {
        ;(findSendButtonForAbort(tree).props as { onPress?: () => void }).onPress?.()
      })
    }).not.toThrow()
  })
})
