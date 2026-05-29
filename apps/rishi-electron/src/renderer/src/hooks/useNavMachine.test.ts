// apps/electron/src/renderer/src/hooks/useNavMachine.test.ts
//
// Atomicity contract: useNavMachine MUST publish navState and navDirection
// in a single zustand setState call. subscribeWithSelector listeners fire
// synchronously inside the originating `set()`, so a sequential write
// (setNavState first, setNavDirection second) lets a navState-only
// subscriber observe the new state alongside the *previous* direction.
//
// In production that subscriber is useNavBridge — and the gap silently
// re-introduces the stale-direction bug: an EPUB-prev-curl followed by an
// EPUB-next-curl would forward direction='backward' from the prior nav
// and snap the player to the new page's last paragraph instead of 0.
//
// This regression test renders the real hook against a stubbed rendition
// and drives it through CURL_PREV → CURL_COMMIT → CURL_NEXT. At every
// idle→non-idle transition the captured (navState, navDirection) pair
// must reflect the *current* navigation's direction, never the previous
// one.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useNavStore } from '@/stores/navStore'
import { useNavMachine } from './useNavMachine'
import type { Rendition } from 'epubjs/types'

function makeRendition(): Rendition {
  return {
    next: vi.fn().mockResolvedValue(undefined),
    prev: vi.fn().mockResolvedValue(undefined),
    display: vi.fn().mockResolvedValue(undefined),
    on: vi.fn(),
    off: vi.fn()
  } as unknown as Rendition
}

beforeEach(() => {
  useNavStore.setState({
    navState: 'idle',
    navDirection: 'forward',
    send: null
  })
})

afterEach(() => {
  useNavStore.setState({
    navState: 'idle',
    navDirection: 'forward',
    send: null
  })
})

describe('useNavMachine — navStore atomicity', () => {
  it('publishes navState and navDirection in the same snapshot on every transition', () => {
    const rendition = makeRendition()
    renderHook(() => useNavMachine(rendition))

    // Capture the (navState, navDirection) pair every time navState changes.
    // If useNavMachine writes sequentially, the first capture inside a
    // transition will see the stale direction from the previous nav.
    const observed: Array<{ navState: string; navDirection: string }> = []
    const unsub = useNavStore.subscribe(
      (s) => s.navState,
      (navState) => {
        observed.push({ navState, navDirection: useNavStore.getState().navDirection })
      }
    )

    act(() => {
      useNavStore.getState().send!({ type: 'CURL_PREV' })
    })
    // First nav must publish direction='backward' atomically with state='curling'.
    expect(observed.at(-1)).toEqual({ navState: 'curling', navDirection: 'backward' })

    act(() => {
      // Settle and commit the prev curl so the machine returns to idle.
      useNavStore.getState().send!({ type: 'SETTLED' })
      useNavStore.getState().send!({ type: 'CURL_COMMIT' })
    })
    expect(useNavStore.getState().navState).toBe('idle')

    // Reset capture so we focus on the next transition.
    observed.length = 0

    act(() => {
      useNavStore.getState().send!({ type: 'CURL_NEXT' })
    })
    // The second nav is forward. The CRITICAL assertion: the subscriber
    // sees direction='forward' atomically with state='curling'. On the
    // buggy sequential-write path it would still see 'backward' (the
    // direction we left behind from CURL_PREV).
    expect(observed.at(-1)).toEqual({ navState: 'curling', navDirection: 'forward' })

    unsub()
  })

  it('publishes direction=backward on a NEXT→PREV sequence', () => {
    // Mirror of the above — guards against asymmetry in the pendingAction
    // derivation (`'prev' → backward`, everything else → 'forward').
    const rendition = makeRendition()
    renderHook(() => useNavMachine(rendition))

    const observed: Array<{ navState: string; navDirection: string }> = []
    const unsub = useNavStore.subscribe(
      (s) => s.navState,
      (navState) => {
        observed.push({ navState, navDirection: useNavStore.getState().navDirection })
      }
    )

    act(() => {
      useNavStore.getState().send!({ type: 'NEXT' })
    })
    expect(observed.at(-1)).toEqual({ navState: 'navigating', navDirection: 'forward' })

    act(() => {
      useNavStore.getState().send!({ type: 'SETTLED' })
    })
    observed.length = 0

    act(() => {
      useNavStore.getState().send!({ type: 'PREV' })
    })
    expect(observed.at(-1)).toEqual({ navState: 'navigating', navDirection: 'backward' })

    unsub()
  })
})
