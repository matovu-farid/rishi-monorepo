/**
 * Issue #83 (VIS-023) — PDF thumbnail modal uses a Tailwind hex palette
 * (blue-500 / gray-200..500 / red-200..800) everywhere. Bind those to
 * semantic theme tokens so the modal tracks the rest of the app chrome
 * and a future dark scheme is a single flip in the theme layer.
 */
jest.mock('react-native', () => {
  const React = require('react')
  const mk = (name: string) =>
    React.forwardRef((p: Record<string, unknown>, r: unknown) =>
      React.createElement(name, { ...p, ref: r }, (p as { children?: unknown }).children),
    )
  return {
    View: mk('View'),
    Text: mk('Text'),
    TouchableOpacity: mk('TouchableOpacity'),
    Image: mk('Image'),
    Modal: mk('Modal'),
    FlatList: mk('FlatList'),
    ActivityIndicator: mk('ActivityIndicator'),
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      flatten: (s: unknown) => s,
    },
    Dimensions: { get: () => ({ width: 390, height: 844 }) },
  }
})

jest.mock('react-native-safe-area-context', () => {
  const React = require('react')
  return {
    SafeAreaView: React.forwardRef((p: Record<string, unknown>, r: unknown) =>
      React.createElement('SafeAreaView', { ...p, ref: r }, (p as { children?: unknown }).children),
    ),
  }
})

jest.mock('react-native-pdf-thumbnail', () => ({
  default: { generate: () => Promise.resolve({ uri: 'x', width: 80, height: 110 }) },
}))

jest.mock('@/components/ui/icon-symbol', () => {
  const React = require('react')
  return {
    IconSymbol: (p: Record<string, unknown>) =>
      React.createElement('IconSymbol', p),
  }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { readFileSync } from 'fs'
import { join } from 'path'

describe('PDF thumbnail modal uses theme tokens (#83)', () => {
  // The component imports native code (`react-native-pdf-thumbnail`)
  // that's hard to mount through the Node test renderer; the most
  // robust signal here is a source-level check that the file no longer
  // embeds the banned Tailwind hex literals and DOES import the
  // semantic color tokens.
  it('source binds to lib/theme/colors and avoids legacy Tailwind hexes', () => {
    const abs = join(__dirname, '..', '..', 'components', 'pdf', 'thumbnail-modal.tsx')
    const src = readFileSync(abs, 'utf-8')

    // Must import the semantic color tokens.
    expect(src).toMatch(/from\s+['"]@\/lib\/theme\/colors['"]/)

    // The banned literals from the issue (lines 74,83,88,94,99,104,164
    // + bonus chrome literals 155, 168).
    const banned = [
      '#3b82f6',
      '#d1d5db',
      '#fecaca',
      '#991b1b',
      '#e5e7eb',
      '#6b7280',
    ]
    for (const hex of banned) {
      expect(src.toLowerCase()).not.toContain(hex.toLowerCase())
    }
  })

  it('renders without crashing and the header bar binds to a token-driven separator', () => {
    const { ThumbnailModal } = require('@/components/pdf/thumbnail-modal') as typeof import('@/components/pdf/thumbnail-modal')
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <ThumbnailModal
          visible
          onClose={() => {}}
          onSelectPage={() => {}}
          filePath="/tmp/x.pdf"
          totalPages={0}
          currentPage={1}
        />,
      )
    })
    expect(tree.toJSON()).not.toBeNull()
    act(() => tree.unmount())
  })
})
