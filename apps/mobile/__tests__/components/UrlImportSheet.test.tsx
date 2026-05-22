/**
 * UrlImportSheet (mobile) — defect P1-AD.
 *
 * The URL import sheet displays the message thrown by `importBookFromUrl`
 * directly to the user. Previously the importer rethrew the raw fetch
 * status ("Download failed: 404 Not Found"), which the sheet then
 * parroted verbatim — useless for end users.
 *
 * Contract pinned here:
 *   - When `importBookFromUrl` rejects with the mapped "We couldn't find
 *     that file" copy, the sheet shows that exact string.
 *   - Same for "URL requires permission" (401 / 403) and
 *     "Server refused download" (other non-2xx).
 *
 * The sheet itself is unchanged — it forwards `err.message`. The
 * mapping happens upstream in `lib/file-import.ts`. This test guards
 * against regressions where someone wraps / mangles the message before
 * `setErrorMessage`.
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
    Platform: { OS: 'ios', select: <T,>(spec: Record<string, T>): T | undefined => spec.ios ?? spec.default },
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

function getTextById(
  root: TestRenderer.ReactTestRenderer,
  testID: string,
): string | undefined {
  const nodes = root.root.findAll(
    (n) => (n.props as { testID?: string }).testID === testID,
  )
  if (nodes.length === 0) return undefined
  const collect = (children: unknown): string => {
    if (children === null || children === undefined) return ''
    if (typeof children === 'string') return children
    if (Array.isArray(children)) return children.map(collect).join('')
    return ''
  }
  return collect((nodes[0].props as { children: unknown }).children)
}

async function flushPromises(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setImmediate(resolve))
  })
}

async function triggerDownload(
  tree: TestRenderer.ReactTestRenderer,
  url: string,
): Promise<void> {
  // Type into the URL input — onChangeText updates the URL ref.
  const inputs = tree.root.findAll(
    (n) =>
      (n.props as { testID?: string }).testID === 'url-input' &&
      typeof (n.props as { onChangeText?: (t: string) => void }).onChangeText ===
        'function',
  )
  expect(inputs.length).toBeGreaterThan(0)
  const onChangeText = (inputs[0].props as { onChangeText: (t: string) => void })
    .onChangeText
  act(() => {
    onChangeText(url)
  })

  // Press the download button. (Mocked react-native components use
  // forwardRef so findAll matches both the outer wrapper and the host
  // element — picking the first is fine since onPress is the same fn.)
  const buttons = tree.root.findAll(
    (n) =>
      (n.props as { testID?: string }).testID === 'url-download-button' &&
      typeof (n.props as { onPress?: () => void }).onPress === 'function',
  )
  expect(buttons.length).toBeGreaterThan(0)
  await act(async () => {
    ;(buttons[0].props as { onPress: () => void }).onPress()
  })
  await flushPromises()
}

describe('UrlImportSheet — P1-AD: surfaces mapped HTTP-error copy', () => {
  beforeEach(() => {
    mockImportBookFromUrl.mockReset()
  })

  it('shows "We couldn\'t find that file" when the importer rejects with that message (404)', async () => {
    mockImportBookFromUrl.mockRejectedValueOnce(
      new Error("We couldn't find that file"),
    )

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <UrlImportSheet
          visible={true}
          onDismiss={() => {}}
          onImported={() => {}}
        />,
      )
    })

    await triggerDownload(tree, 'https://example.com/missing.epub')

    expect(getTextById(tree, 'url-import-error')).toBe(
      "We couldn't find that file",
    )
  })

  it('shows "URL requires permission" when the importer rejects with that message (401/403)', async () => {
    mockImportBookFromUrl.mockRejectedValueOnce(
      new Error('URL requires permission'),
    )

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <UrlImportSheet
          visible={true}
          onDismiss={() => {}}
          onImported={() => {}}
        />,
      )
    })

    await triggerDownload(tree, 'https://example.com/private.epub')

    expect(getTextById(tree, 'url-import-error')).toBe('URL requires permission')
  })

  it('shows "Server refused download" when the importer rejects with that message (5xx)', async () => {
    mockImportBookFromUrl.mockRejectedValueOnce(
      new Error('Server refused download'),
    )

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <UrlImportSheet
          visible={true}
          onDismiss={() => {}}
          onImported={() => {}}
        />,
      )
    })

    await triggerDownload(tree, 'https://example.com/broken.epub')

    expect(getTextById(tree, 'url-import-error')).toBe('Server refused download')
  })

  it('does NOT parrot raw "Download failed: 404 Not Found" (P1-AD regression guard)', async () => {
    // If a future regression brings the raw fetch-status string back,
    // it must not appear in the rendered error.
    mockImportBookFromUrl.mockRejectedValueOnce(
      new Error("We couldn't find that file"),
    )

    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <UrlImportSheet
          visible={true}
          onDismiss={() => {}}
          onImported={() => {}}
        />,
      )
    })

    await triggerDownload(tree, 'https://example.com/missing.epub')

    const text = getTextById(tree, 'url-import-error') ?? ''
    expect(text).not.toMatch(/Download failed:/i)
    expect(text).not.toMatch(/\b404\b/)
  })
})
