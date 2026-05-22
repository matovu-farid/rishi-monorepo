/**
 * Phase 4 — AIChatOrb (mobile).
 *
 * The orb is a 52pt glass disk rendering 4 vertical bars + (optionally)
 * a pulse ring. The `chatStatus` prop drives animation state and
 * accessibility label; the ring is rendered only while `chatStatus`
 * is `'connecting'`.
 *
 * Per ARCH §2 the visible contract is:
 *   - Component mounts (without crashing) for each of the 4 statuses.
 *   - `accessibilityLabel` matches the A11Y_LABELS map.
 *   - Pressing the orb invokes `onPress`.
 *   - The pulse ring `<testID='ai-chat-orb-ring'>` is rendered ONLY in
 *     the 'connecting' state.
 *   - Default `testID='ai-chat-orb'`; consumer can override via prop.
 *
 * Mock strategy: GlassDisk is mocked to a plain View wrapper so we don't
 * pull expo-blur into this suite. Reanimated calls are captured into
 * loose stubs (shared-value-style getter/setter) — we don't assert on
 * specific timings here (that's an implementation detail), only on the
 * rendered tree per status.
 *
 * Red signal: `@/components/chat/AIChatOrb` does not exist yet.
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
      announceForAccessibility: jest.fn(),
    },
  }
})

jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, bottom: 0, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// Reanimated stub with shared-value capture + timing helpers.
jest.mock('react-native-reanimated', () => {
  const React = require('react')
  const View = React.forwardRef((p: any, r: unknown) =>
    React.createElement('Animated.View', { ...p, ref: r }, p.children),
  )
  const passthrough = (v: unknown) => v
  return {
    __esModule: true,
    default: { View, createAnimatedComponent: (c: unknown) => c },
    View,
    useSharedValue: (v: unknown) => ({ value: v }),
    useAnimatedStyle: () => ({}),
    useReducedMotion: () => false,
    withTiming: passthrough,
    withSpring: passthrough,
    withDelay: (_d: number, v: unknown) => v,
    withSequence: (...vs: unknown[]) => vs,
    withRepeat: (v: unknown) => v,
    cancelAnimation: jest.fn(),
    Easing: {
      out: () => null,
      quad: null,
      inOut: () => null,
      linear: null,
    },
    interpolate: (v: number) => v,
    Extrapolation: { CLAMP: 'clamp' },
    FadeIn: { duration: () => ({ build: () => ({}) }) },
    FadeOut: { duration: () => ({ build: () => ({}) }) },
  }
})

jest.mock('expo-blur', () => {
  const React = require('react')
  const BlurView = (p: any) =>
    React.createElement('BlurView', { testID: 'blur-view', ...p }, p.children)
  return { __esModule: true, BlurView }
})

jest.mock('expo-haptics', () => ({
  impactAsync: jest.fn(),
  selectionAsync: jest.fn(),
  notificationAsync: jest.fn(),
  ImpactFeedbackStyle: { Soft: 'soft', Light: 'light', Medium: 'medium' },
  NotificationFeedbackType: { Success: 'success', Warning: 'warning' },
}))

// GlassDisk is the primitive AIChatOrb wraps. Stub it so the suite isn't
// coupled to the GlassDisk render tree. Virtual so we can mock the path
// even when the source file doesn't exist yet (it lands in Stage A).
jest.mock(
  '@/components/ui/GlassDisk',
  () => {
    const React = require('react')
    const GlassDisk = (p: any) =>
      React.createElement('GlassDisk', { testID: 'glass-disk', ...p }, p.children)
    return { __esModule: true, GlassDisk }
  },
  { virtual: true },
)

// Shared tokens — ensure ORB_COLORS is resolvable via the mapped path.
jest.mock('@rishi/shared/tokens/orb-colors', () => ({
  __esModule: true,
  ORB_COLORS: {
    idle: 'rgba(88, 86, 214, 0.70)',
    connecting: 'rgba(59, 130, 246, 0.80)',
    thinking: 'rgba(251, 191, 36, 0.80)',
    speaking: 'rgba(34, 197, 94, 0.80)',
  },
  // WGT-013 — the orb now reads its disk tint from the shared scale so
  // electron + mobile stay in lockstep. The mock exposes a sentinel tint
  // per status that the "uses shared ORB_DISK_TINTS" assertion below
  // searches for in the rendered GlassDisk's tintColor.
  ORB_DISK_TINTS: {
    idle: 'rgba(88, 86, 214, 0.24)',
    connecting: 'rgba(59, 130, 246, 0.24)',
    thinking: 'rgba(251, 191, 36, 0.24)',
    speaking: 'rgba(34, 197, 94, 0.24)',
  },
}))

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import { AccessibilityInfo, Pressable } from 'react-native'
import { AIChatOrb } from '@/components/chat/AIChatOrb'
import type { AIChatOrbStatus } from '@rishi/shared/tokens/orb-colors'

const A11Y_LABELS: Record<AIChatOrbStatus, string> = {
  idle: 'AI chat',
  connecting: 'AI chat — connecting',
  thinking: 'AI chat — thinking',
  speaking: 'AI chat — speaking',
}

function findFirstPressable(
  tree: TestRenderer.ReactTestRenderer,
): TestRenderer.ReactTestInstance {
  return tree.root.findAll((n) => n.type === Pressable)[0]
}

describe('AIChatOrb (mobile)', () => {
  it.each(['idle', 'connecting', 'thinking', 'speaking'] as const)(
    'renders without crashing for chatStatus=%s',
    (status) => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus={status} onPress={() => undefined} />,
        )
      })
      const root = tree.root.findAll(
        (n) => (n.props as { testID?: string } | null)?.testID === 'ai-chat-orb',
      )
      expect(root.length).toBeGreaterThan(0)
    },
  )

  it.each(['idle', 'connecting', 'thinking', 'speaking'] as const)(
    'sets accessibilityLabel correctly for chatStatus=%s',
    (status) => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus={status} onPress={() => undefined} />,
        )
      })
      const labelled = tree.root.findAll(
        (n) =>
          (n.props as { accessibilityLabel?: string } | null)
            ?.accessibilityLabel === A11Y_LABELS[status],
      )
      expect(labelled.length).toBeGreaterThan(0)
    },
  )

  it('fires onPress when pressed', () => {
    const onPress = jest.fn()
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AIChatOrb chatStatus="idle" onPress={onPress} />,
      )
    })
    const pressable = findFirstPressable(tree)
    expect(pressable).toBeTruthy()
    act(() => {
      ;(pressable.props as { onPress: () => void }).onPress()
    })
    expect(onPress).toHaveBeenCalledTimes(1)
  })

  it.each(['idle', 'thinking', 'speaking'] as const)(
    'does NOT render the pulse ring for chatStatus=%s',
    (status) => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus={status} onPress={() => undefined} />,
        )
      })
      const ring = tree.root.findAll(
        (n) =>
          (n.props as { testID?: string } | null)?.testID === 'ai-chat-orb-ring',
      )
      expect(ring.length).toBe(0)
    },
  )

  it('renders the pulse ring for chatStatus="connecting"', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AIChatOrb chatStatus="connecting" onPress={() => undefined} />,
      )
    })
    const ring = tree.root.findAll(
      (n) =>
        (n.props as { testID?: string } | null)?.testID === 'ai-chat-orb-ring',
    )
    expect(ring.length).toBeGreaterThan(0)
  })

  it('uses default testID="ai-chat-orb" when no testID prop is passed', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AIChatOrb chatStatus="idle" onPress={() => undefined} />,
      )
    })
    const tagged = tree.root.findAll(
      (n) => (n.props as { testID?: string } | null)?.testID === 'ai-chat-orb',
    )
    expect(tagged.length).toBeGreaterThan(0)
  })

  describe('a11y: accessibilityValue + announceForAccessibility (P1-P)', () => {
    beforeEach(() => {
      ;(
        AccessibilityInfo.announceForAccessibility as jest.Mock
      ).mockClear()
    })

    it.each(['idle', 'connecting', 'thinking', 'speaking'] as const)(
      'sets accessibilityValue.text to match the status label for chatStatus=%s',
      (status) => {
        let tree!: TestRenderer.ReactTestRenderer
        act(() => {
          tree = TestRenderer.create(
            <AIChatOrb chatStatus={status} onPress={() => undefined} />,
          )
        })
        const valued = tree.root.findAll(
          (n) =>
            (n.props as { accessibilityValue?: { text?: string } } | null)
              ?.accessibilityValue?.text === A11Y_LABELS[status],
        )
        expect(valued.length).toBeGreaterThan(0)
      },
    )

    it('does NOT announce on initial mount with chatStatus="idle"', () => {
      act(() => {
        TestRenderer.create(
          <AIChatOrb chatStatus="idle" onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).not.toHaveBeenCalled()
    })

    it('announces the new label when chatStatus transitions idle -> connecting', () => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus="idle" onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).not.toHaveBeenCalled()

      act(() => {
        tree.update(
          <AIChatOrb chatStatus="connecting" onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenCalledTimes(1)
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenLastCalledWith(A11Y_LABELS.connecting)
    })

    it('announces again when chatStatus reverts (connecting -> idle)', () => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus="idle" onPress={() => undefined} />,
        )
      })
      act(() => {
        tree.update(
          <AIChatOrb chatStatus="connecting" onPress={() => undefined} />,
        )
      })
      act(() => {
        tree.update(
          <AIChatOrb chatStatus="idle" onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenCalledTimes(2)
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).toHaveBeenLastCalledWith(A11Y_LABELS.idle)
    })

    it('does NOT re-announce when chatStatus stays the same across renders', () => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus="thinking" onPress={() => undefined} />,
        )
      })
      ;(
        AccessibilityInfo.announceForAccessibility as jest.Mock
      ).mockClear()
      act(() => {
        tree.update(
          <AIChatOrb chatStatus="thinking" onPress={() => undefined} />,
        )
      })
      expect(
        AccessibilityInfo.announceForAccessibility,
      ).not.toHaveBeenCalled()
    })
  })

  describe('WGT-013 — disk tint comes from shared ORB_DISK_TINTS', () => {
    // The orb's glass disk used to read a locally-duplicated `ORB_TINTS`
    // constant. After WGT-013 it must read from
    // `@rishi/shared/tokens/orb-colors` so electron + mobile cannot drift.
    // We verify by looking at the `tintColor` prop the orb passes to the
    // mocked GlassDisk for each status — the value must match the
    // sentinels exposed by the shared-tokens mock above.
    const SHARED_DISK_TINTS: Record<AIChatOrbStatus, string> = {
      idle: 'rgba(88, 86, 214, 0.24)',
      connecting: 'rgba(59, 130, 246, 0.24)',
      thinking: 'rgba(251, 191, 36, 0.24)',
      speaking: 'rgba(34, 197, 94, 0.24)',
    }

    it.each(['idle', 'connecting', 'thinking', 'speaking'] as const)(
      'passes ORB_DISK_TINTS[%s] as tintColor to the GlassDisk',
      (status) => {
        let tree!: TestRenderer.ReactTestRenderer
        act(() => {
          tree = TestRenderer.create(
            <AIChatOrb chatStatus={status} onPress={() => undefined} />,
          )
        })
        const disk = tree.root.findAll(
          (n) =>
            (n.props as { testID?: string } | null)?.testID === 'glass-disk',
        )[0]
        expect(disk).toBeTruthy()
        expect(
          (disk.props as { tintColor?: string }).tintColor,
        ).toBe(SHARED_DISK_TINTS[status])
      },
    )
  })

  describe('WGT-015 — hitSlop covers the connecting ring extent', () => {
    // The pulse ring scales to ~1.15× a 56pt extent (so ~64pt visual
    // radius from the Pressable's 52pt origin). The previous hitSlop=4
    // gave us a 60pt tap target — users who tapped the ring edge during
    // "connecting" got nothing. Bumping hitSlop to ≥8 covers the ring's
    // max extent.
    it('Pressable hitSlop is ≥ 8 on every edge', () => {
      let tree!: TestRenderer.ReactTestRenderer
      act(() => {
        tree = TestRenderer.create(
          <AIChatOrb chatStatus="connecting" onPress={() => undefined} />,
        )
      })
      const pressable = findFirstPressable(tree)
      const hitSlop = (
        pressable.props as {
          hitSlop?:
            | number
            | { top?: number; bottom?: number; left?: number; right?: number }
        }
      ).hitSlop
      // Accept either form — number-shorthand or per-edge object.
      if (typeof hitSlop === 'number') {
        expect(hitSlop).toBeGreaterThanOrEqual(8)
      } else if (hitSlop && typeof hitSlop === 'object') {
        expect(hitSlop.top ?? 0).toBeGreaterThanOrEqual(8)
        expect(hitSlop.bottom ?? 0).toBeGreaterThanOrEqual(8)
        expect(hitSlop.left ?? 0).toBeGreaterThanOrEqual(8)
        expect(hitSlop.right ?? 0).toBeGreaterThanOrEqual(8)
      } else {
        throw new Error(
          'Expected AIChatOrb Pressable to declare a hitSlop ≥ 8 (number or object).',
        )
      }
    })
  })

  it('honors a custom testID prop (overrides default)', () => {
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(
        <AIChatOrb
          chatStatus="idle"
          onPress={() => undefined}
          testID="custom-orb"
        />,
      )
    })
    const tagged = tree.root.findAll(
      (n) => (n.props as { testID?: string } | null)?.testID === 'custom-orb',
    )
    expect(tagged.length).toBeGreaterThan(0)
    const dflt = tree.root.findAll(
      (n) => (n.props as { testID?: string } | null)?.testID === 'ai-chat-orb',
    )
    // When a custom testID is supplied, the default string must not appear.
    expect(dflt.length).toBe(0)
  })
})
