/**
 * DAT-017 (#129): UrlImportSheet must cancel the in-flight download
 * when the user dismisses the sheet. Previously `handleClose` returned
 * early while a download was in flight, leaving the user stuck.
 *
 * Contract pinned here:
 *   - The sheet creates an AbortController per download and forwards
 *     its signal to `importBookFromUrl`.
 *   - Dismissing the sheet during download calls `.abort()` on the
 *     controller and tears down the sheet (calls onDismiss).
 *   - When the importer rejects with an AbortError, the sheet does
 *     NOT surface an error banner (the user initiated the cancel).
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
    ActivityIndicator: mk('ActivityIndicator'),
    TouchableOpacity: mk('TouchableOpacity'),
    TextInput: mk('TextInput'),
    Keyboard: { dismiss: jest.fn() },
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
  }
})

const mockImportBookFromUrl = jest.fn()
jest.mock('@/lib/file-import', () => ({
  __esModule: true,
  importBookFromUrl: (...args: unknown[]) => mockImportBookFromUrl(...args),
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { UrlImportSheet } from '@/components/UrlImportSheet'

function findByTestId(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
  filterFn?: (n: TestRenderer.ReactTestInstance) => boolean,
): TestRenderer.ReactTestInstance[] {
  return tree.root.findAll(
    (n) =>
      (n.props as { testID?: string }).testID === testID &&
      (filterFn ? filterFn(n) : true),
  )
}

async function flushPromises(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setImmediate(resolve))
  })
}

function makeDeferred<T>(): {
  promise: Promise<T>
  resolve: (v: T) => void
  reject: (e: unknown) => void
} {
  let resolve!: (v: T) => void
  let reject!: (e: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('UrlImportSheet — DAT-017 abort on dismiss', () => {
  beforeEach(() => {
    mockImportBookFromUrl.mockReset()
  })

  it('aborts the in-flight import when the user dismisses during download', async () => {
    // The mocked importer respects the supplied signal — it rejects with
    // an AbortError when the signal aborts and otherwise hangs forever.
    let receivedSignal: AbortSignal | undefined
    mockImportBookFromUrl.mockImplementationOnce(
      (_url: string, opts?: { signal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          receivedSignal = opts?.signal
          if (opts?.signal?.aborted) {
            const e = new Error('aborted'); e.name = 'AbortError'
            return reject(e)
          }
          opts?.signal?.addEventListener('abort', () => {
            const e = new Error('aborted'); e.name = 'AbortError'
            reject(e)
          })
        }),
    )

    const onDismiss = jest.fn()
    const onImported = jest.fn()

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <UrlImportSheet visible={true} onDismiss={onDismiss} onImported={onImported} />,
      )
    })

    // Type a URL.
    const inputs = findByTestId(
      tree,
      'url-input',
      (n) =>
        typeof (n.props as { onChangeText?: (t: string) => void }).onChangeText ===
        'function',
    )
    act(() => {
      ;(inputs[0].props as { onChangeText: (t: string) => void }).onChangeText(
        'https://example.com/big.epub',
      )
    })

    // Press Download — kicks off the (hanging) importer.
    const buttons = findByTestId(
      tree,
      'url-download-button',
      (n) =>
        typeof (n.props as { onPress?: () => void }).onPress === 'function',
    )
    await act(async () => {
      ;(buttons[0].props as { onPress: () => void }).onPress()
    })

    // Importer was called with a signal.
    expect(mockImportBookFromUrl).toHaveBeenCalledTimes(1)
    expect(receivedSignal).toBeDefined()
    expect(receivedSignal!.aborted).toBe(false)

    // Tap the backdrop (TouchableOpacity above the sheet content) to dismiss.
    // The first TouchableOpacity in the rendered tree is the backdrop; it
    // has no testID, so we find it by looking for an onPress handler that
    // isn't the download button.
    const backdrops = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string }).testID === undefined &&
        (n.props as { activeOpacity?: number }).activeOpacity === 1 &&
        typeof (n.props as { onPress?: () => void }).onPress === 'function',
    )
    expect(backdrops.length).toBeGreaterThan(0)
    await act(async () => {
      ;(backdrops[0].props as { onPress: () => void }).onPress()
    })
    await flushPromises()

    // The signal is aborted, onDismiss fired, and we did NOT surface an error.
    expect(receivedSignal!.aborted).toBe(true)
    expect(onDismiss).toHaveBeenCalled()
    expect(onImported).not.toHaveBeenCalled()
    // Error banner should NOT be rendered.
    const errors = findByTestId(tree, 'url-import-error')
    expect(errors).toHaveLength(0)
  })
})
