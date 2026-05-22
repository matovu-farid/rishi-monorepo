/**
 * Phase 4 — TabLayout mount of GlobalMiniPlayer (P0-Q + P0-R).
 *
 * Verifies the architectural decision documented in the GlobalMiniPlayer
 * test: GlobalMiniPlayer now lives INSIDE the Tabs subtree (via the
 * `<Tabs screenLayout={…}>` prop) rather than as a sibling of `<Slot/>`
 * at the root layout.
 *
 * Why screenLayout and not just a sibling of `<Tabs>`:
 *   - `useBottomTabBarHeight()` throws unless called from inside a
 *     screen of the bottom-tab navigator. screenLayout wraps each
 *     screen and lives INSIDE the navigator's screen context, so
 *     the hook resolves.
 *   - Stack routes like `/reader/[id]` and `/chat/[bookId]` live
 *     OUTSIDE `(tabs)/`. Mounting GlobalMiniPlayer in screenLayout
 *     means it cannot render on those routes — fixing the P0-R bug
 *     where the player floated 49pt above the home indicator on
 *     /chat/[bookId] (a stack route with no tab bar).
 *
 * Pinned behaviour (2 tests):
 *   1. `(tabs)/_layout.tsx` passes a `screenLayout` to `<Tabs>` whose
 *      output includes `<GlobalMiniPlayer />` rendered alongside the
 *      screen children.
 *   2. The root `app/_layout.tsx` source NO LONGER references
 *      `GlobalMiniPlayer` (the mount has moved entirely).
 */

// ── Mocks ────────────────────────────────────────────────────────────────
// Captures whatever value `(tabs)/_layout.tsx` passes to the <Tabs>
// `screenLayout` prop so the test can invoke it directly and inspect the
// rendered subtree. The mock also renders `screenLayout({ children: null })`
// so the integration is exercised end-to-end.
const capturedTabsProps: { current: Record<string, unknown> | null } = {
  current: null,
}

jest.mock('expo-router', () => {
  const React = require('react')
  const Tabs: any = (props: Record<string, unknown>) => {
    capturedTabsProps.current = props
    const screenLayout = props.screenLayout as
      | ((args: { children: React.ReactNode }) => React.ReactNode)
      | undefined
    if (screenLayout) {
      return React.createElement(
        'TabsRoot',
        { testID: 'tabs-root' },
        screenLayout({ children: React.createElement('TabScreen', { testID: 'tab-screen' }) }),
      )
    }
    return React.createElement('TabsRoot', { testID: 'tabs-root' }, props.children as React.ReactNode)
  }
  Tabs.Screen = ({ children }: { children?: React.ReactNode }) => children ?? null
  return {
    __esModule: true,
    Tabs,
    Redirect: ({ href }: { href: string }) =>
      require('react').createElement('Redirect', { testID: `redirect-${href}` }),
    Slot: ({ children }: { children: React.ReactNode }) => children,
    Stack: Object.assign(
      ({ children }: { children: React.ReactNode }) => children,
      { Screen: ({ children }: { children: React.ReactNode }) => children ?? null },
    ),
    usePathname: () => '/(tabs)/index',
    useRouter: () => ({ push: jest.fn(), replace: jest.fn(), back: jest.fn() }),
  }
})

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
  useSafeAreaInsets: () => ({ top: 44, bottom: 34, left: 0, right: 0 }),
  SafeAreaProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// Auth + tutorial stores — the layout reads these and would redirect or
// short-circuit otherwise. We return authenticated + tour completed.
jest.mock('@/lib/stores/authStore', () => {
  type AuthShape = { isAuthenticated: boolean; authHydrated: boolean }
  const state: AuthShape = { isAuthenticated: true, authHydrated: true }
  return {
    __esModule: true,
    useAuthStore: <T,>(selector: (s: AuthShape) => T) => selector(state),
  }
})
jest.mock('@/lib/stores/tutorialStore', () => {
  type TutShape = { tourCompleted: boolean; startTour: () => void }
  const state: TutShape = { tourCompleted: true, startTour: () => undefined }
  return {
    __esModule: true,
    useTutorialStore: <T,>(selector: (s: TutShape) => T) => selector(state),
  }
})
jest.mock('@/lib/sync/triggers', () => ({
  __esModule: true,
  startSyncTriggers: () => undefined,
  stopSyncTriggers: () => undefined,
}))
jest.mock('@/app/_layout', () => ({
  __esModule: true,
  IS_E2E_TEST: false,
}))

// Stub heavy/leaf components.
jest.mock('@/components/haptic-tab', () => ({
  __esModule: true,
  HapticTab: (p: any) => null,
}))
jest.mock('@/components/ui/icon-symbol', () => ({
  __esModule: true,
  IconSymbol: (p: any) => null,
}))
jest.mock('@/components/onboarding/TourProvider', () => ({
  __esModule: true,
  TourProvider: () => null,
}))
jest.mock('@/components/UploadErrorSnackbar', () => ({
  __esModule: true,
  UploadErrorSnackbar: () => null,
}))
jest.mock('@/constants/theme', () => ({
  __esModule: true,
  Colors: { light: { tint: '#000' }, dark: { tint: '#fff' } },
}))
jest.mock('@/hooks/use-color-scheme', () => ({
  __esModule: true,
  useColorScheme: () => 'light',
}))

// Stub GlobalMiniPlayer with a sentinel so we can locate it in the tree.
jest.mock('@/components/player/GlobalMiniPlayer', () => {
  const React = require('react')
  const GlobalMiniPlayer = () =>
    React.createElement('GlobalMiniPlayerSentinel', {
      testID: 'global-mini-player-mount',
    })
  return { __esModule: true, GlobalMiniPlayer }
})

import React, { act } from 'react'
import TestRenderer from 'react-test-renderer'
import * as fs from 'node:fs'
import * as path from 'node:path'

import TabLayout from '@/app/(tabs)/_layout'

function findByTestID(
  tree: TestRenderer.ReactTestRenderer,
  testID: string,
): TestRenderer.ReactTestInstance | null {
  const matches = tree.root.findAll(
    (n) => (n.props as { testID?: string } | null)?.testID === testID,
  )
  return matches[0] ?? null
}

describe('TabLayout mounts GlobalMiniPlayer inside Tabs (P0-Q + P0-R)', () => {
  it('passes a screenLayout to <Tabs> that renders <GlobalMiniPlayer />', () => {
    capturedTabsProps.current = null
    let tree!: TestRenderer.ReactTestRenderer
    act(() => {
      tree = TestRenderer.create(<TabLayout />)
    })
    // <Tabs> received a screenLayout prop.
    expect(capturedTabsProps.current).not.toBeNull()
    expect(typeof capturedTabsProps.current!.screenLayout).toBe('function')

    // And invoking screenLayout (which the mocked Tabs does for us)
    // rendered the GlobalMiniPlayer sentinel into the tree.
    expect(findByTestID(tree, 'global-mini-player-mount')).not.toBeNull()
  })

  it('root app/_layout.tsx no longer imports or renders GlobalMiniPlayer', () => {
    // Static source check: the mount has moved entirely to (tabs)/.
    // Reading the file (rather than evaluating it) sidesteps Sentry +
    // ExecuTorch init + all the deep-link plumbing the root layout
    // pulls in at module load. We assert the absence of (a) an import
    // statement and (b) JSX usage. A documentation comment referencing
    // GlobalMiniPlayer is allowed and intentional — it explains WHY
    // the mount moved.
    const rootLayoutPath = path.join(
      __dirname,
      '..',
      '..',
      'app',
      '_layout.tsx',
    )
    const src = fs.readFileSync(rootLayoutPath, 'utf8')
    // No import of GlobalMiniPlayer.
    expect(src).not.toMatch(/import\s+\{[^}]*GlobalMiniPlayer[^}]*\}/)
    // No JSX usage of <GlobalMiniPlayer …/> or <GlobalMiniPlayer>.
    expect(src).not.toMatch(/<GlobalMiniPlayer[\s/>]/)
  })
})
