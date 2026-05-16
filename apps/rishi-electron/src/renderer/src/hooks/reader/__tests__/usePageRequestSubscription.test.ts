import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlayerStore } from '@/stores/playerStore'

// Wave 3 will create src/renderer/src/hooks/reader/usePageRequestSubscription.ts.
const HOOK_PATH = '@/hooks/' + 'reader/usePageRequestSubscription'

type UsePageRequestSubscription = (params: {
  onNext: () => void | Promise<void>
  onPrev: () => void | Promise<void>
  autoClear: boolean
}) => void

async function loadHook(): Promise<UsePageRequestSubscription> {
  const mod = (await import(/* @vite-ignore */ HOOK_PATH)) as {
    usePageRequestSubscription: UsePageRequestSubscription
  }
  return mod.usePageRequestSubscription
}

let originalSubscribe: typeof usePlayerStore.subscribe
let subscribeCount: number
let clearPageRequestSpy: ReturnType<typeof vi.fn<() => void>>

beforeEach(() => {
  subscribeCount = 0
  originalSubscribe = usePlayerStore.subscribe
  // Wrap subscribe to count subscriptions; the inner impl still works so
  // the hook can react to setState updates.
  usePlayerStore.subscribe = ((...args: Parameters<typeof originalSubscribe>) => {
    subscribeCount += 1
    return (originalSubscribe as unknown as (...a: unknown[]) => () => void).apply(
      usePlayerStore,
      args as unknown[]
    )
  }) as typeof usePlayerStore.subscribe

  clearPageRequestSpy = vi.fn<() => void>()
  usePlayerStore.setState({
    pageRequest: null,
    clearPageRequest: clearPageRequestSpy
  })
})

afterEach(() => {
  usePlayerStore.subscribe = originalSubscribe
})

describe('usePageRequestSubscription', () => {
  it('invokes onNext when pageRequest becomes "next"', async () => {
    const usePageRequestSubscription = await loadHook()
    const onNext = vi.fn()
    const onPrev = vi.fn()
    renderHook(() => usePageRequestSubscription({ onNext, onPrev, autoClear: true }))
    act(() => {
      usePlayerStore.setState({ pageRequest: 'next' })
    })
    expect(onNext).toHaveBeenCalledTimes(1)
    expect(onPrev).not.toHaveBeenCalled()
  })

  it('invokes onPrev when pageRequest becomes "prev"', async () => {
    const usePageRequestSubscription = await loadHook()
    const onNext = vi.fn()
    const onPrev = vi.fn()
    renderHook(() => usePageRequestSubscription({ onNext, onPrev, autoClear: true }))
    act(() => {
      usePlayerStore.setState({ pageRequest: 'prev' })
    })
    expect(onPrev).toHaveBeenCalledTimes(1)
    expect(onNext).not.toHaveBeenCalled()
  })

  it('calls clearPageRequest after dispatch when autoClear is true', async () => {
    const usePageRequestSubscription = await loadHook()
    renderHook(() =>
      usePageRequestSubscription({ onNext: vi.fn(), onPrev: vi.fn(), autoClear: true })
    )
    act(() => {
      usePlayerStore.setState({ pageRequest: 'next' })
    })
    expect(clearPageRequestSpy).toHaveBeenCalledTimes(1)
  })

  it('does NOT call clearPageRequest when autoClear is false', async () => {
    const usePageRequestSubscription = await loadHook()
    renderHook(() =>
      usePageRequestSubscription({ onNext: vi.fn(), onPrev: vi.fn(), autoClear: false })
    )
    act(() => {
      usePlayerStore.setState({ pageRequest: 'next' })
    })
    expect(clearPageRequestSpy).not.toHaveBeenCalled()
  })

  it('does not re-subscribe when callbacks change across renders', async () => {
    const usePageRequestSubscription = await loadHook()
    const { rerender } = renderHook(
      ({ onNext, onPrev }: { onNext: () => void; onPrev: () => void }) =>
        usePageRequestSubscription({ onNext, onPrev, autoClear: true }),
      { initialProps: { onNext: vi.fn(), onPrev: vi.fn() } }
    )
    const subsAfterMount = subscribeCount
    // Re-render with new callback references — should NOT re-subscribe.
    rerender({ onNext: vi.fn(), onPrev: vi.fn() })
    rerender({ onNext: vi.fn(), onPrev: vi.fn() })
    expect(subscribeCount).toBe(subsAfterMount)
  })

  it('routes pageRequest events to the latest callback after re-render', async () => {
    const usePageRequestSubscription = await loadHook()
    const firstOnNext = vi.fn()
    const secondOnNext = vi.fn()
    const { rerender } = renderHook(
      ({ onNext }: { onNext: () => void }) =>
        usePageRequestSubscription({ onNext, onPrev: vi.fn(), autoClear: true }),
      { initialProps: { onNext: firstOnNext } }
    )
    rerender({ onNext: secondOnNext })
    act(() => {
      usePlayerStore.setState({ pageRequest: 'next' })
    })
    expect(secondOnNext).toHaveBeenCalledTimes(1)
    expect(firstOnNext).not.toHaveBeenCalled()
  })
})
