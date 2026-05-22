/**
 * WGT-009 — `useAutoCollapseTimer` hook.
 *
 * MiniPlayer used to duplicate the same setTimeout/clearTimeout dance in
 * two places: a `useEffect` that watched `expanded` + `isPlaying`, and a
 * `bumpCollapse` callback fired from each control press. Both did the
 * exact same thing — start a 4s timer that flips expanded false, but
 * only when expanded and not actively playing. Any future change to the
 * delay or the guard predicate had to be made in both spots.
 *
 * The extracted hook owns one shared timer ref and exposes a `bump()`
 * function for the imperative re-arm. The reactive effect-driven arm
 * (when expanded/isPlaying changes) lives inside the hook.
 *
 * Behaviour pins (Jest fake timers): see individual `it` blocks. We host
 * the hook in a tiny `<TestHost/>` component because `apps/mobile` does
 * not depend on `@testing-library/react`'s `renderHook`.
 */

// Minimal react-native mock so React hooks can run under react-test-renderer
// without pulling in the native module.
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
    StyleSheet: { create: (s: Record<string, unknown>) => s },
    Platform: { OS: 'ios', select: (s: any) => s.ios ?? s.default },
    useColorScheme: () => 'light',
  }
})

import React, { act, useImperativeHandle, forwardRef } from 'react'
import TestRenderer from 'react-test-renderer'

import { useAutoCollapseTimer } from '@/components/player/useAutoCollapseTimer'

interface HostProps {
  expanded: boolean
  isPlaying: boolean
  delayMs: number
  onCollapse: () => void
}
interface HostHandle {
  bump: () => void
}

const TestHost = forwardRef<HostHandle, HostProps>(function TestHost(
  { expanded, isPlaying, delayMs, onCollapse },
  ref,
) {
  const api = useAutoCollapseTimer({ expanded, isPlaying, delayMs, onCollapse })
  useImperativeHandle(ref, () => ({ bump: api.bump }), [api])
  return null
})

function mountHost(props: HostProps): {
  ref: React.RefObject<HostHandle | null>
  rerender: (next: HostProps) => void
  unmount: () => void
} {
  const ref = React.createRef<HostHandle>()
  let renderer!: TestRenderer.ReactTestRenderer
  act(() => {
    renderer = TestRenderer.create(<TestHost ref={ref} {...props} />)
  })
  return {
    ref,
    rerender(next: HostProps) {
      act(() => {
        renderer.update(<TestHost ref={ref} {...next} />)
      })
    },
    unmount() {
      act(() => {
        renderer.unmount()
      })
    },
  }
}

describe('useAutoCollapseTimer (WGT-009)', () => {
  beforeEach(() => {
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('does NOT fire onCollapse before the delay elapses', () => {
    const onCollapse = jest.fn()
    mountHost({ expanded: true, isPlaying: false, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(3999)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })

  it('fires onCollapse once after the delay when expanded && !isPlaying', () => {
    const onCollapse = jest.fn()
    mountHost({ expanded: true, isPlaying: false, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(4000)
    })
    expect(onCollapse).toHaveBeenCalledTimes(1)
  })

  it('does NOT arm a timer when expanded=false', () => {
    const onCollapse = jest.fn()
    mountHost({ expanded: false, isPlaying: false, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(10000)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })

  it('does NOT arm a timer while isPlaying=true', () => {
    const onCollapse = jest.fn()
    mountHost({ expanded: true, isPlaying: true, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(10000)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })

  it('bump() defers the pending collapse', () => {
    const onCollapse = jest.fn()
    const { ref } = mountHost({
      expanded: true,
      isPlaying: false,
      delayMs: 4000,
      onCollapse,
    })
    act(() => {
      jest.advanceTimersByTime(3000)
    })
    act(() => {
      ref.current!.bump()
    })
    act(() => {
      jest.advanceTimersByTime(900)
    })
    expect(onCollapse).not.toHaveBeenCalled()
    act(() => {
      jest.advanceTimersByTime(3100)
    })
    expect(onCollapse).toHaveBeenCalledTimes(1)
  })

  it('cleans up on unmount — no late collapse fires', () => {
    const onCollapse = jest.fn()
    const { unmount } = mountHost({
      expanded: true,
      isPlaying: false,
      delayMs: 4000,
      onCollapse,
    })
    act(() => {
      jest.advanceTimersByTime(2000)
    })
    unmount()
    act(() => {
      jest.advanceTimersByTime(10000)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })

  it('flipping isPlaying=true cancels the pending collapse', () => {
    const onCollapse = jest.fn()
    const { rerender } = mountHost({
      expanded: true,
      isPlaying: false,
      delayMs: 4000,
      onCollapse,
    })
    act(() => {
      jest.advanceTimersByTime(2000)
    })
    rerender({ expanded: true, isPlaying: true, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(10000)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })

  it('flipping expanded=false cancels the pending collapse', () => {
    const onCollapse = jest.fn()
    const { rerender } = mountHost({
      expanded: true,
      isPlaying: false,
      delayMs: 4000,
      onCollapse,
    })
    act(() => {
      jest.advanceTimersByTime(2000)
    })
    rerender({ expanded: false, isPlaying: false, delayMs: 4000, onCollapse })
    act(() => {
      jest.advanceTimersByTime(10000)
    })
    expect(onCollapse).not.toHaveBeenCalled()
  })
})
