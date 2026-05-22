/**
 * Phase 4 — GlassDisk primitive (mobile).
 *
 * GlassDisk wraps `expo-blur`'s BlurView in a rounded clipped surface and
 * exposes the recipe shared by AIChatOrb / VoiceChatLauncher / MiniPlayer.
 * Per ARCH §1 the render tree is two Views deep — an outer shadow wrapper
 * and an inner `overflow:'hidden'` clipper containing:
 *
 *   - <BlurView … />              (always)
 *   - tint overlay <View />       (only when `tintColor` is provided)
 *   - hairline border <View />    (always; decorative)
 *   - children
 *
 * Pinned observable behaviour (5 tests):
 *   1. A BlurView element appears in the tree.
 *   2. Outer container width + height equal the `size` prop.
 *   3. `testID` prop appears in the tree.
 *   4. When `tintColor` is provided, a tint overlay View exists with that
 *      backgroundColor.
 *   5. When `tintColor` is omitted, no tint overlay is rendered.
 *
 * Red signal: `@/components/ui/GlassDisk` does not exist yet — the import
 * itself throws "Cannot find module".
 *
 * Mocks: react-native primitives, expo-blur (BlurView host stub),
 * react-native-safe-area-context (passthrough). No reanimated calls in
 * GlassDisk itself, so the reanimated stub is unused here.
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
    StyleSheet: {
      create: (s: Record<string, unknown>) => s,
      absoluteFill: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      absoluteFillObject: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
      hairlineWidth: 0.5,
    },
    Platform: {
      OS: 'ios',
      select: <T,>(spec: Record<string, T>): T | undefined =>
        spec.ios ?? spec.default,
    },
    useColorScheme: () => 'light',
    AccessibilityInfo: {
      isReduceMotionEnabled: jest.fn(async () => false),
      addEventListener: jest.fn(() => ({ remove: jest.fn() })),
    },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// expo-blur — render BlurView as a host node we can find by tag.
jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { GlassDisk } from '@/components/ui/GlassDisk'

/** Flatten a possibly-array style prop into a single object. */
function flattenStyle(style: unknown): Record<string, unknown> {
  if (!style) return {}
  if (Array.isArray(style)) {
    return Object.assign({}, ...style.map((s) => flattenStyle(s)))
  }
  return style as Record<string, unknown>
}

/** Find all host nodes (any depth) whose tag name matches. */
function findHosts(
  tree: TestRenderer.ReactTestRenderer,
  tag: string,
): TestRenderer.ReactTestInstance[] {
  return tree.root.findAll(
    (n) => typeof n.type === 'string' && (n.type as string) === tag,
  )
}

describe('GlassDisk (mobile)', () => {
  it('renders a BlurView inside the disk', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlassDisk size={52} />)
    })
    const blurs = findHosts(tree, 'BlurView')
    expect(blurs.length).toBeGreaterThan(0)
  })

  it('applies the size prop to the inner clipping container width + height', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlassDisk size={52} />)
    })
    // The inner clip View is the one whose style carries both width and
    // height equal to size. Walk all View nodes and find that one.
    const views = findHosts(tree, 'View')
    const matches = views.filter((v) => {
      const s = flattenStyle((v.props as { style?: unknown }).style)
      return s.width === 52 && s.height === 52
    })
    expect(matches.length).toBeGreaterThan(0)
  })

  it('renders the testID prop on a node in the tree', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <GlassDisk size={52} testID="my-glass-disk" />,
      )
    })
    const tagged = tree.root.findAll(
      (n) => (n.props as { testID?: string } | null)?.testID === 'my-glass-disk',
    )
    expect(tagged.length).toBeGreaterThan(0)
  })

  it('renders a tint overlay View when `tintColor` is provided', () => {
    const tint = 'rgba(88,86,214,0.24)'
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlassDisk size={52} tintColor={tint} />)
    })
    const views = findHosts(tree, 'View')
    const overlay = views.filter((v) => {
      const s = flattenStyle((v.props as { style?: unknown }).style)
      return s.backgroundColor === tint
    })
    expect(overlay.length).toBeGreaterThan(0)
  })

  it('renders NO tint overlay View when `tintColor` is omitted', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<GlassDisk size={52} />)
    })
    // No View should carry one of the 4 tint colors from ORB_TINTS.
    const tints = [
      'rgba(88,86,214,0.24)',
      'rgba(59,130,246,0.24)',
      'rgba(251,191,36,0.24)',
      'rgba(34,197,94,0.24)',
    ]
    const views = findHosts(tree, 'View')
    const tinted = views.filter((v) => {
      const s = flattenStyle((v.props as { style?: unknown }).style)
      return typeof s.backgroundColor === 'string' && tints.includes(s.backgroundColor as string)
    })
    expect(tinted.length).toBe(0)
  })
})
