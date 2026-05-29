// apps/electron/src/renderer/src/hooks/player/useNavBridge.test.ts
//
// Regression: when the user presses the next-page button while playing,
// the player must land on paragraph 0 of the new view. Previously the
// bridge derived the PAGE_NAVIGATING direction from the player's stale
// context.direction — so if the player had been navigated BACKWARD just
// before (e.g. PREV at the first paragraph, landing on the previous
// page's last paragraph), the subsequent next-page click would still
// report direction='backward' and the new page would land on its LAST
// paragraph instead of paragraph 0.
//
// The bridge must instead read the *actual* nav direction the user just
// requested, published by useNavMachine on navStore.navDirection.
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useNavStore } from '@/stores/navStore'
import { useNavBridge } from './useNavBridge'
import type { PlayerActor } from '@/hooks/player/usePlayerActor'

function makeFakeActor(opts: { direction: 'forward' | 'backward' }) {
  const send = vi.fn()
  const actor = {
    send,
    getSnapshot: () => ({
      value: 'playing',
      context: { direction: opts.direction }
    })
  } as unknown as PlayerActor
  return { actor, send }
}

beforeEach(() => {
  useNavStore.setState({
    navState: 'idle',
    navDirection: 'forward',
    send: null
  })
})

describe('useNavBridge', () => {
  it('sends PAGE_NAVIGATING with the navs actual forward direction even if player.direction is stale=backward', () => {
    const { actor, send } = makeFakeActor({ direction: 'backward' })
    renderHook(() => useNavBridge(actor))

    // User presses the EPUB next-page button → navMachine starts a forward
    // navigation. The hook publishes navState='curling' (or 'navigating')
    // together with navDirection='forward' so consumers learn the actual
    // intent of the request, not whatever direction the player had stored.
    act(() => {
      useNavStore.setState({ navState: 'curling', navDirection: 'forward' })
    })

    expect(send).toHaveBeenCalledWith({
      type: 'PAGE_NAVIGATING',
      direction: 'forward'
    })
  })

  it('sends PAGE_NAVIGATING with the navs actual backward direction even if player.direction is stale=forward', () => {
    const { actor, send } = makeFakeActor({ direction: 'forward' })
    renderHook(() => useNavBridge(actor))

    act(() => {
      useNavStore.setState({ navState: 'curling', navDirection: 'backward' })
    })

    expect(send).toHaveBeenCalledWith({
      type: 'PAGE_NAVIGATING',
      direction: 'backward'
    })
  })
})
